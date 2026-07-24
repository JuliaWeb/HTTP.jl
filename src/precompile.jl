using PrecompileTools: @setup_workload, @compile_workload

# Shared high-level workload used by package precompilation.

function _precompile_trace_enabled()::Bool
    value = get(ENV, "HTTP_PRECOMPILE_TRACE", "")
    return value == "1" || lowercase(value) == "true" || lowercase(value) == "yes"
end

function _precompile_trace(message::AbstractString)::Nothing
    _precompile_trace_enabled() || return nothing
    println(stderr, "[HTTP precompile] ", message)
    flush(stderr)
    return nothing
end

function _precompile_body_string(body::AbstractBody)::String
    out = UInt8[]
    buf = Vector{UInt8}(undef, 256)
    while true
        n = body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    @try_ignore begin
        body_close!(body)
    end
    return String(out)
end

_precompile_body_string(body::AbstractVector{UInt8}) = String(body)
_precompile_body_string(body::AbstractString) = String(body)

function _precompile_encoded_bytes(text::AbstractString, encoding::Symbol)::Vector{UInt8}
    bytes = collect(codeunits(String(text)))
    if encoding == :gzip
        return transcode(CodecZlib.GzipCompressor, bytes)
    elseif encoding == :deflate
        return transcode(CodecZlib.ZlibCompressor, bytes)
    end
    throw(ArgumentError("unknown precompile encoding: $(encoding)"))
end

function _precompile_encoded_response(text::AbstractString, encoding::Symbol)::Response
    encoded = _precompile_encoded_bytes(text, encoding)
    header_value = encoding == :gzip ? "gzip" : "deflate"
    return Response(
        200,
        BytesBody(encoded);
        headers=["Content-Encoding" => header_value],
        content_length=length(encoded),
    )
end

function _precompile_text_response(
    text::AbstractString,
    status::Integer=200,
    headers=Pair{String,String}[],
    proto_major::Integer=1,
    proto_minor::Integer=1,
)::Response
    payload = collect(codeunits(String(text)))
    return Response(
        status,
        BytesBody(payload);
        headers=headers,
        content_length=length(payload),
        proto_major=proto_major,
        proto_minor=proto_minor,
    )
end

function _precompile_reset_default_client!()::Nothing
    client = nothing
    lock(_DEFAULT_CLIENT_LOCK)
    try
        client = _DEFAULT_CLIENT[]
        _DEFAULT_CLIENT[] = nothing
    finally
        unlock(_DEFAULT_CLIENT_LOCK)
    end
    client === nothing || close(client::Client)
    return nothing
end

function _precompile_tls_config(cert_file::String, key_file::String)::TLS.Config
    return TLS.Config(
        nothing,
        false,
        false,
        TLS.ClientAuthMode.NoClientCert,
        cert_file,
        key_file,
        nothing,
        nothing,
        ["http/1.1"],
        UInt16[],
        Int64(0),
        TLS.TLS1_2_VERSION,
        nothing,
        false,
        64,
    )
end

function _run_precompile_workload_inner!()::Nothing
    _precompile_trace("inner start")
    request_server = nothing
    stream_server = nothing
    file_server = nothing
    h2_server = nothing
    tls_server = nothing
    ws_server = nothing
    client = nothing
    h2_client = nothing
    temp_dir = mktempdir()
    try
        _precompile_trace("build request router")
        request_router = Router()
        register!(request_router, "GET", "/hello/{name}", Handlers.handlertimeout(0.5)(req ->
            _precompile_text_response("hello:" * getparam(req, "name"))
        ))
        register!(request_router, "POST", "/echo/{name}", Handlers.handlertimeout(0.5)(req -> begin
            payload = _precompile_body_string(req.body)
            return _precompile_text_response("echo:" * getparam(req, "name") * ":" * payload)
        end))
        register!(request_router, "QUERY", "/search/{name}", Handlers.handlertimeout(0.5)(req -> begin
            content_type = header(req, "Content-Type", "")
            payload = _precompile_body_string(req.body)
            response_headers = ["Accept-Query" => "application/x-www-form-urlencoded"]
            req.method == "QUERY" || return Response(405, EmptyBody(); content_length=0)
            occursin("application/x-www-form-urlencoded", content_type) || return Response(415, EmptyBody(); content_length=0)
            return _precompile_text_response("query:" * getparam(req, "name") * ":" * payload, 200, response_headers)
        end))
        register!(request_router, "QUERY", "/search-redirect", req ->
            Response(
                307,
                EmptyBody();
                headers=["Location" => "/search/redirected"],
                content_length=0,
            )
        )
        register!(request_router, "GET", "/redirect", req ->
            Response(
                302,
                EmptyBody();
                headers=["Location" => "/hello/redirected"],
                content_length=0,
            )
        )
        register!(request_router, "GET", "/cookie", req -> begin
            cookie_header = header(req, "Cookie", nothing)
            if cookie_header === nothing || !occursin("precompile=1", cookie_header::String)
                return _precompile_text_response(
                    "cookie:set",
                    200,
                    ["Set-Cookie" => "precompile=1; Path=/"],
                )
            end
            return _precompile_text_response("cookie:seen")
        end)

        servecontent_payload = collect(codeunits("range payload"))
        servecontent_modtime = DateTime(2024, 1, 1, 0, 0, 0)
        register!(request_router, "GET", "/content", req ->
            servecontent(
                req,
                servecontent_payload;
                name="demo.txt",
                etag="\"precompile-v1\"",
                modtime=servecontent_modtime,
            )
        )
        register!(request_router, "GET", "/gzip", req -> _precompile_encoded_response("gzip:decoded", :gzip))
        register!(request_router, "GET", "/deflate", req -> _precompile_encoded_response("deflate:decoded", :deflate))

        _precompile_trace("start request server")
        request_server = serve!(request_router, "127.0.0.1", 0; listenany=true)
        _precompile_trace("start stream server")
        stream_server = listen!("127.0.0.1", 0; listenany=true) do stream
            request = startread(stream)
            payload = read(stream, String)
            setstatus(stream, 200)
            setheader(stream, "Content-Type", "text/plain; charset=utf-8")
            write(stream, "stream:" * request.target * ":" * payload)
            return nothing
        end

        write(joinpath(temp_dir, "hello.txt"), "static hello")
        _precompile_trace("start file server")
        file_server = serve!(fileserver(temp_dir; etag=:weak_stat), "127.0.0.1", 0; listenany=true)

        _precompile_trace("start h2 server")
        h2_server = serve!("127.0.0.1", 0; listenany=true) do request
            return _precompile_text_response(
                "h2:" * request.target,
                200,
                Pair{String,String}[],
                2,
                0,
            )
        end

        tls_resource_dir = normpath(joinpath(@__DIR__, "..", "test", "resources"))
        tls_cert_path = joinpath(tls_resource_dir, "unittests.crt")
        tls_key_path = joinpath(tls_resource_dir, "unittests.key")
        tls_listener = TLS.listen(
            "tcp",
            "127.0.0.1:0",
            _precompile_tls_config(tls_cert_path, tls_key_path);
            backlog=128,
        )
        _precompile_trace("start tls server")
        tls_server = serve!(tls_listener) do request
            return _precompile_text_response("tls:" * request.target)
        end

        _precompile_trace("start websocket server")
        ws_server = WebSockets.listen!("127.0.0.1", 0) do ws
            for msg in ws
                WebSockets.send(ws, uppercase(String(msg)))
            end
            return nothing
        end

        request_address = server_addr(request_server)
        stream_address = server_addr(stream_server)
        file_address = server_addr(file_server)
        h2_address = server_addr(h2_server)
        tls_address = server_addr(tls_server)
        ws_url = "ws://" * WebSockets.server_addr(ws_server::WebSockets.Server) * "/echo"

        request_timeouts = (
            connect_timeout=60.0,
            request_timeout=60.0,
            response_header_timeout=60.0,
            read_idle_timeout=60.0,
        )
        stream_timeouts = (
            connect_timeout=60.0,
            request_timeout=60.0,
            response_header_timeout=60.0,
            read_idle_timeout=60.0,
            write_idle_timeout=60.0,
        )

        client = Client(
            transport=Transport(proxy=ProxyConfig(), max_idle_per_host=4, max_idle_total=4),
            cookiejar=CookieJar(),
            prefer_http2=false,
        )
        h2_client = Client(
            transport=Transport(proxy=ProxyConfig(), max_idle_per_host=4, max_idle_total=4),
            prefer_http2=true,
        )

        _precompile_trace("request top-level")
        top_level = get(URI("http://$(request_address)/hello/uri"); proxy=ProxyConfig(), request_timeouts...)
        @assert top_level.status == 200
        @assert String(top_level.body) == "hello:uri"

        _precompile_trace("request echo")
        echo = post("http://$(request_address)/echo/jane"; client=client, body="ping", stream_timeouts...)
        @assert echo.status == 200
        @assert String(echo.body) == "echo:jane:ping"

        _precompile_trace("request query")
        query_headers = ["Content-Type" => "application/x-www-form-urlencoded"]
        query_resp = request("QUERY", "http://$(request_address)/search/jane", query_headers, (term="ping",); client=client, stream_timeouts...)
        @assert query_resp.status == 200
        @assert header(query_resp, "Accept-Query", nothing) == "application/x-www-form-urlencoded"
        @assert String(query_resp.body) == "query:jane:term=ping"

        _precompile_trace("request query redirect")
        query_redirect = request("QUERY", "http://$(request_address)/search-redirect", query_headers, "term=redirect"; client=client, stream_timeouts...)
        @assert query_redirect.status == 200
        @assert header(query_redirect, "Accept-Query", nothing) == "application/x-www-form-urlencoded"
        @assert String(query_redirect.body) == "query:redirected:term=redirect"

        _precompile_trace("request redirect")
        redirected = get("http://$(request_address)/redirect"; client=client, request_timeouts...)
        @assert redirected.status == 200
        @assert String(redirected.body) == "hello:redirected"

        _precompile_trace("request cookie first")
        cookie_first = get("http://$(request_address)/cookie"; client=client, request_timeouts...)
        @assert cookie_first.status == 200
        @assert String(cookie_first.body) == "cookie:set"
        _precompile_trace("request cookie second")
        cookie_second = get("http://$(request_address)/cookie"; client=client, request_timeouts...)
        @assert cookie_second.status == 200
        @assert String(cookie_second.body) == "cookie:seen"

        _precompile_trace("request buffered")
        buffer = IOBuffer()
        buffered = request("GET", "http://$(request_address)/hello/buffer"; client=client, response_stream=buffer, request_timeouts...)
        @assert buffered.status == 200
        @assert String(take!(buffer)) == "hello:buffer"

        _precompile_trace("request stream")
        streamed_body = Ref("")
        streamed = open(:POST, "http://$(stream_address)/stream"; client=client, retry=false, stream_timeouts...) do stream
            write(stream, "payload")
            response_meta = startread(stream)
            @assert response_meta.status == 200
            streamed_body[] = read(stream, String)
        end
        @assert streamed.status == 200
        @assert streamed.body === nothing
        @assert streamed_body[] == "stream:/stream:payload"

        _precompile_trace("request static")
        static_resp = get("http://$(file_address)/hello.txt"; client=client, request_timeouts...)
        @assert static_resp.status == 200
        @assert String(static_resp.body) == "static hello"

        _precompile_trace("request range")
        range_resp = get("http://$(request_address)/content", ["Range" => "bytes=0-4"]; client=client, request_timeouts...)
        @assert range_resp.status == 206
        @assert String(range_resp.body) == "range"
        @assert header(range_resp, "Content-Range", nothing) == "bytes 0-4/13"

        _precompile_trace("request gzip")
        gzip_resp = get("http://$(request_address)/gzip"; client=client, request_timeouts...)
        @assert gzip_resp.status == 200
        @assert String(gzip_resp.body) == "gzip:decoded"

        _precompile_trace("request deflate")
        deflate_resp = get("http://$(request_address)/deflate"; client=client, request_timeouts...)
        @assert deflate_resp.status == 200
        @assert String(deflate_resp.body) == "deflate:decoded"

        _precompile_trace("request tls")
        tls_resp = get("https://$(tls_address)/secure"; proxy=ProxyConfig(), require_ssl_verification=false, protocol=:h1, request_timeouts...)
        @assert tls_resp.status == 200
        @assert String(tls_resp.body) == "tls:/secure"

        _precompile_trace("request h2")
        h2_resp = get("http://$(h2_address)/h2"; client=h2_client, protocol=:h2)
        @assert h2_resp.status == 200
        @assert h2_resp.proto_major == 2
        @assert String(h2_resp.body) == "h2:/h2"

        _precompile_trace("request websocket")
        ws_reply = WebSockets.open(ws_url; proxy=ProxyConfig(), stream_timeouts...) do ws
            WebSockets.send(ws, "ping!")
            return WebSockets.receive(ws)
        end
        @assert ws_reply == "PING!"
    finally
        _precompile_trace("cleanup start")
        @try_ignore begin
            _precompile_trace("cleanup default client")
            _precompile_reset_default_client!()
        end
        for owned in (client, h2_client)
            owned === nothing && continue
            @try_ignore begin
                _precompile_trace("cleanup owned client")
                close(owned::Client)
            end
        end
        for server in (request_server, stream_server, file_server, h2_server, tls_server)
            server === nothing && continue
            @try_ignore begin
                _precompile_trace("cleanup server")
                forceclose(server)
            end
        end
        if ws_server !== nothing
            @try_ignore begin
                _precompile_trace("cleanup websocket server")
                close(ws_server::WebSockets.Server)
            end
        end
        _precompile_trace("cleanup temp dir")
        rm(temp_dir; force=true, recursive=true)
        _precompile_trace("cleanup done")
    end
    _precompile_trace("inner done")
    return nothing
end

function _run_precompile_workload!()::Nothing
    _precompile_trace("outer start")
    try
        _run_precompile_workload_inner!()
    finally
        _precompile_shutdown!()
    end
    _precompile_trace("outer done")
    return nothing
end

function _precompile_shutdown!()::Nothing
    @try_ignore begin
        _precompile_trace("outer host resolver shutdown")
        HostResolvers.shutdown!()
    end
    @try_ignore begin
        _precompile_trace("outer shutdown")
        IOPoll.shutdown!()
    end
    return nothing
end

function is_julia_automerge()
    name = "JULIA_REGISTRYCI_AUTOMERGE"
    value = get(ENV, name, "false")
    maybe_b = tryparse(Bool, value)
    b = maybe_b == true
    return b
end

function _precompile_workload_enabled()::Bool
    # explicit opt-out: the workload starts real servers/requests, which must not run
    # inside static compilation (e.g. `juliac --trim` builds, where it segfaults)
    get(ENV, "HTTP_PRECOMPILE_WORKLOAD", "1") in ("0", "false", "FALSE", "no", "NO") && return false
    Base.JLOptions().code_coverage == 0 || return false

    # https://github.com/JuliaWeb/HTTP.jl/issues/1280
    is_julia_automerge() && return false

    return _precompile_host_resolver_available()
end

function _precompile_host_resolver_available()::Bool
    try
        return !isempty(HostResolvers.resolve_tcp_addrs("tcp", "localhost:0"))
    catch
        return false
    finally
        @try_ignore begin
            HostResolvers.shutdown!()
        end
    end
end

if _precompile_workload_enabled()
    try
        _precompile_trace("enabled")
        @setup_workload begin
            @compile_workload begin
                _run_precompile_workload!()
            end
        end
    catch err
        @info "Ignoring an error that occurred during the precompilation workload" exception=(err, catch_backtrace())
    end
else
    _precompile_trace("disabled")
end
