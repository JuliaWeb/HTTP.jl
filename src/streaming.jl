@enum ResponseState NotStarted OnMessageBegin StatusComplete OnHeaderField OnHeaderValue HeadersDone OnBody BodyDone EarlyEOF UpgradeConnection

type ResponseStream{T<:IO} <: IO
    response::Response
    socket::T
    state::ResponseState
    buffer::IOBuffer
    parser::ResponseParser
    timeout::Float64
    current_header::Nullable{Compat.UTF8String}
    state_change::Condition
    cookie_buffer::IOBuffer
    ResponseStream() = new()
end

function ResponseStream{T}(response, socket::T)
    r = ResponseStream{T}()
    r.response = response
    r.socket = socket
    r.state = NotStarted
    r.buffer = IOBuffer()
    r.parser = ResponseParser(r)
    r.timeout = Inf
    r.current_header = Nullable()
    r.state_change = Condition()
    r.cookie_buffer = IOBuffer()
    r
end

function Base.show(io::IO, stream::ResponseStream)
    print(io, "ResponseStream($(requestfor(stream)))")
end

function send_headers(response_stream::ResponseStream)
    request = requestfor(response_stream)
    print(response_stream, request.method, " ", isempty(request.resource) ? "/" : request.resource,
          " HTTP/1.1", CRLF,
          map(h->string(h,": ",request.headers[h],CRLF), collect(keys(request.headers)))...,
          "", CRLF)
    response_stream
end

immutable TimeoutException <: Exception
    timeout::Float64
end

function Base.show(io::IO, err::TimeoutException)
    print(io, "TimeoutException: server did not respond for more than $(err.timeout) seconds. ")
end

function process_response(stream)
    rp = stream.parser
    last_received = now()
    status_channel = Channel{Symbol}(1)
    timeout = stream.timeout
    if timeout < Inf
        Timer(0, timeout) do timer
            delta = now() - last_received
            if timeout_in_sec(delta) > timeout
                close(timer)
                put!(status_channel, :timeout)
            end
        end
    end
    @schedule begin
        while stream.state < BodyDone && !eof(stream.socket)
            last_received = now()
            data = readavailable(stream.socket)
            if length(data) > 0
                add_data(rp, data)
            end
        end
        put!(status_channel, :success)
    end
    status = take!(status_channel)
    status == :timeout && throw(TimeoutException(timeout))
    if stream.state < BodyDone
        stream.state = EarlyEOF
        notify(stream.state_change)
    end
    stream
end

function tls_dbg(level, filename, number, msg)
    warn("MbedTLS emitted debug info: $msg in $filename:$number")
end

function get_default_tls_config(verify=true)
    conf = MbedTLS.SSLConfig()
    MbedTLS.config_defaults!(conf)

    entropy = MbedTLS.Entropy()
    rng = MbedTLS.CtrDrbg()
    MbedTLS.seed!(rng, entropy)
    MbedTLS.rng!(conf, rng)

    MbedTLS.authmode!(conf,
      verify ? MbedTLS.MBEDTLS_SSL_VERIFY_REQUIRED : MbedTLS.MBEDTLS_SSL_VERIFY_NONE)
    MbedTLS.dbg!(conf, tls_dbg)
    MbedTLS.ca_chain!(conf)

    conf
end

function Base.wait(stream::ResponseStream)
    stream.state >= BodyDone && return
    wait(stream.state_change)
end

function Base.eof(stream::ResponseStream)
    eof(stream.buffer) && (stream.state==BodyDone || eof(stream.socket))
end

for T in [BitArray, Vector{UInt8}, UInt8]
    @eval Base.write(stream::ResponseStream, data::$T) = write(stream.socket, data)
end


function Base.readbytes!(stream::ResponseStream, data::Vector{UInt8}, sz)
    while stream.state < BodyDone && nb_available(stream) < sz
        wait(stream)
    end
    readbytes!(stream.buffer, data, sz)
end

function Base.read(stream::ResponseStream)
    while stream.state < BodyDone
        wait(stream)
    end
    takebuf_array(stream.buffer)
end

function Base.read(stream::ResponseStream, ::Type{UInt8})
    while !eof(stream) && nb_available(stream) < 1
        wait(stream)
    end
    read(stream.buffer, UInt8)
end

function Base.readavailable(stream::ResponseStream)
    while nb_available(stream) == 0
        wait(stream)
    end
    read(stream, nb_available(stream))
end

Base.close(stream::ResponseStream) = close(stream.socket)
Base.nb_available(stream::ResponseStream) = nb_available(stream.buffer)

for getter in [:headers, :cookies, :statuscode, :requestfor, :history]
    @eval $getter(stream::ResponseStream) = $getter(stream.response)
end

Base.convert(::Type{Response}, stream::ResponseStream) = stream.response

immutable ProxyException <: Exception
    resp::Response
end

function Base.show(io::IO, err::ProxyException)
    print(io, "Failed to open CONNECT tunnel on proxy server. Proxy response was $(err.resp)")
end

function open_stream(req::Request, tls_conf=TLS_VERIFY, timeout=Inf,
                     http_proxy=Nullable{URI}(), https_proxy=Nullable{URI}())
    uri = req.uri
    connect_method = :direct
    if scheme(uri) == "http"
        if !isnull(http_proxy)
            uri = get(http_proxy)
            connect_method = :tunnel
        end
    elseif scheme(uri) == "https"
        if !isnull(https_proxy)
            uri = get(https_proxy)
            connect_method = :tunnel
        end
    else
        error("Unsupported scheme \"$(scheme(uri))\"")
    end
    if connect_method == :tunnel
        req.resource = "$(req.uri.scheme)://$(req.uri.host)$(resourcefor(req.uri))"
    end
    ip = Base.getaddrinfo(uri.host)
    if scheme(req.uri) == "http"
        stream = Base.connect(ip, http_port(uri))
    else
        # Initialize HTTPS
        if connect_method == :tunnel
            sock = Base.connect(ip, http_port(uri))
            tunnel_req = Request()
            tunnel_req.method = "CONNECT"
            tunnel_resp = Response()
            tunnel_resp.request = Nullable(tunnel_req)
            tunnel_resp_stream = ResponseStream(tunnel_resp, sock)
            tunnel_resp_stream.timeout = timeout
            write(sock, "CONNECT $(req.uri.host):$(https_port(req.uri)) HTTP/1.1\r\n\r\n")
            process_response(tunnel_resp_stream)
            if statuscode(tunnel_resp) ≠ 200
                throw(ProxyException(tunnel_resp))
            end
        else
            sock = Base.connect(ip, uri.port == 0 ? 443 : uri.port)
        end
        stream = MbedTLS.SSLContext()
        MbedTLS.setup!(stream, tls_conf)
        MbedTLS.set_bio!(stream, sock)
        MbedTLS.hostname!(stream, req.uri.host)
        MbedTLS.handshake(stream)
    end
    resp = Response()
    empty!(resp.headers)
    resp.request = Nullable(req)
    stream = ResponseStream(resp, stream)
    stream.timeout = timeout
    send_headers(stream)
    stream
end

function __init_streaming__()
    global const TLS_VERIFY = get_default_tls_config(true)
    global const TLS_NOVERIFY = get_default_tls_config(false)
end
