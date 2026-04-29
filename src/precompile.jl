using PrecompileTools: @setup_workload, @compile_workload

# Shared high-level workload used by package precompilation.

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

function _run_precompile_workload_inner!()::Nothing
    request_server = nothing
    stream_server = nothing
    file_server = nothing
    h2_server = nothing
    ws_server = nothing
    client = nothing
    h2_client = nothing
    temp_dir = mktempdir()
    try
        request_router = Router()
        register!(request_router, "GET", "/hello/{name}", Handlers.handlertimeout(0.5)(req ->
            _precompile_text_response("hello:" * getparam(req, "name"))
        ))
        register!(request_router, "POST", "/echo/{name}", Handlers.handlertimeout(0.5)(req -> begin
            payload = _precompile_body_string(req.body)
            return _precompile_text_response("echo:" * getparam(req, "name") * ":" * payload)
        end))
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

        request_server = serve!(request_router, "127.0.0.1", 0; listenany=true)
        stream_server = listen!("127.0.0.1", 0; listenany=true) do stream
            request = startread(stream)
            payload = read(stream, String)
            setstatus(stream, 200)
            setheader(stream, "Content-Type", "text/plain; charset=utf-8")
            write(stream, "stream:" * request.target * ":" * payload)
            return nothing
        end

        write(joinpath(temp_dir, "hello.txt"), "static hello")
        file_server = serve!(fileserver(temp_dir; etag=:weak_stat), "127.0.0.1", 0; listenany=true)

        h2_server = serve!("127.0.0.1", 0; listenany=true) do request
            return _precompile_text_response(
                "h2:" * request.target,
                200,
                Pair{String,String}[],
                2,
                0,
            )
        end

        ws_server = WebSockets.listen!("127.0.0.1", 0) do ws
            for msg in ws
                WebSockets.send(ws, uppercase(String(msg)))
            end
            return nothing
        end

        request_address = "127.0.0.1:$(port(request_server))"
        stream_address = "127.0.0.1:$(port(stream_server))"
        file_address = "127.0.0.1:$(port(file_server))"
        h2_address = "127.0.0.1:$(port(h2_server))"
        ws_url = "ws://" * WebSockets.server_addr(ws_server::WebSockets.Server) * "/echo"

        request_timeouts = (
            connect_timeout=1.0,
            request_timeout=5.0,
            response_header_timeout=5.0,
            read_idle_timeout=5.0,
        )
        stream_timeouts = (
            connect_timeout=1.0,
            request_timeout=5.0,
            response_header_timeout=5.0,
            read_idle_timeout=5.0,
            write_idle_timeout=5.0,
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

        top_level = get(URI("http://$(request_address)/hello/uri"); proxy=ProxyConfig(), request_timeouts...)
        @assert top_level.status == 200
        @assert String(top_level.body) == "hello:uri"

        echo = post("http://$(request_address)/echo/jane"; client=client, body="ping", stream_timeouts...)
        @assert echo.status == 200
        @assert String(echo.body) == "echo:jane:ping"

        redirected = get("http://$(request_address)/redirect"; client=client, request_timeouts...)
        @assert redirected.status == 200
        @assert String(redirected.body) == "hello:redirected"

        cookie_first = get("http://$(request_address)/cookie"; client=client, request_timeouts...)
        @assert cookie_first.status == 200
        @assert String(cookie_first.body) == "cookie:set"
        cookie_second = get("http://$(request_address)/cookie"; client=client, request_timeouts...)
        @assert cookie_second.status == 200
        @assert String(cookie_second.body) == "cookie:seen"

        buffer = IOBuffer()
        buffered = request("GET", "http://$(request_address)/hello/buffer"; client=client, response_stream=buffer, request_timeouts...)
        @assert buffered.status == 200
        @assert String(take!(buffer)) == "hello:buffer"

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

        static_resp = get("http://$(file_address)/hello.txt"; client=client, request_timeouts...)
        @assert static_resp.status == 200
        @assert String(static_resp.body) == "static hello"

        range_resp = get("http://$(request_address)/content", ["Range" => "bytes=0-4"]; client=client, request_timeouts...)
        @assert range_resp.status == 206
        @assert String(range_resp.body) == "range"
        @assert header(range_resp, "Content-Range", nothing) == "bytes 0-4/13"

        h2_resp = get("http://$(h2_address)/h2"; client=h2_client, protocol=:h2)
        @assert h2_resp.status == 200
        @assert h2_resp.proto_major == 2
        @assert String(h2_resp.body) == "h2:/h2"

        ws_reply = WebSockets.open(ws_url; proxy=ProxyConfig(), stream_timeouts...) do ws
            WebSockets.send(ws, "ping!")
            return WebSockets.receive(ws)
        end
        @assert ws_reply == "PING!"
    finally
        @try_ignore begin
            _precompile_reset_default_client!()
        end
        for owned in (client, h2_client)
            owned === nothing && continue
            @try_ignore begin
                close(owned::Client)
            end
        end
        for server in (request_server, stream_server, file_server, h2_server)
            server === nothing && continue
            @try_ignore begin
                forceclose(server)
            end
        end
        if ws_server !== nothing
            @try_ignore begin
                WebSockets.forceclose(ws_server::WebSockets.Server)
            end
        end
        rm(temp_dir; force=true, recursive=true)
    end
    return nothing
end

function _run_precompile_workload!()::Nothing
    task = Threads.@spawn _run_precompile_workload_inner!()
    try
        status = IOPoll.timedwait(() -> istaskdone(task), 20.0; pollint = 0.01)
        if status == :timed_out
            @try_ignore begin
                IOPoll.shutdown!()
            end
            @try_ignore begin
                Base.throwto(task, InterruptException())
            end
            _ = IOPoll.timedwait(() -> istaskdone(task), 2.0; pollint = 0.01)
            error("HTTP precompile workload timed out")
        end
        fetch(task)
    finally
        @try_ignore begin
            IOPoll.shutdown!()
        end
    end
    return nothing
end

function _precompile_workload_enabled()::Bool
    Base.JLOptions().code_coverage == 0 || return false
    try
        return !isempty(HostResolvers.resolve_tcp_addrs("tcp", "localhost:0"))
    catch
        return false
    end
end

if _precompile_workload_enabled()
    try
        @setup_workload begin
            @compile_workload begin
                _run_precompile_workload!()
            end
        end
    catch err
        @info "Ignoring an error that occurred during the precompilation workload" exception=(err, catch_backtrace())
    end
end
