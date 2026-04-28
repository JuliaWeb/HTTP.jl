# Streaming HTTP client API built on top of the shared client execution path.
export startread
export closeread

import Base: close, closewrite, eof, isopen, read, readbytes!, write

function _client_stream_request(
    method::Union{AbstractString,Symbol},
    parsed::_URLParts,
    headers::Headers,
    request_timeout_ns::Int64,
    timeout_config::Union{Nothing,_RequestTimeoutConfig},
)::Request{EmptyBody}
    context = RequestContext()
    _apply_request_timeout_settings!(context, request_timeout_ns, timeout_config)
    return Request{EmptyBody}(
        String(method),
        parsed.target,
        copy(headers),
        Headers(),
        EmptyBody(),
        parsed.address,
        Int64(0),
        UInt8(1),
        UInt8(1),
        false,
        context,
    )
end

function Stream(
    method::Union{AbstractString,Symbol},
    parsed::_URLParts,
    headers::Headers,
    client::Client,
    owns_client::Bool;
    proxy_config::ProxyConfig,
    cookies::Union{Bool,Vector{Cookie}},
    cookiejar::Union{Nothing,CookieJar},
    redirect::Bool,
    redirect_policy::_RedirectPolicy,
    protocol::Symbol,
    decompress::Union{Nothing,Bool},
    request_timeout_ns::Integer,
    timeout_config::Union{Nothing,_RequestTimeoutConfig},
    retry_controller::Union{Nothing,_RetryController},
)
    request_timeout_ns >= 0 || throw(ArgumentError("request_timeout_ns must be >= 0"))
    request = _client_stream_request(
        method,
        parsed,
        headers,
        Int64(request_timeout_ns),
        timeout_config,
    )
    return Stream{true,typeof(request)}(
        parsed,
        client,
        owns_client,
        proxy_config,
        cookies,
        cookiejar,
        redirect,
        redirect_policy,
        protocol,
        decompress,
        Int64(request_timeout_ns),
        timeout_config,
        retry_controller,
        IOBuffer(),
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        request,
        EmptyBody(),
        Int64(0),
        nothing,
        nothing,
        nothing,
        UInt32(0),
        false,
        false,
        false,
        false,
        false,
        false,
        _ServerStreamWriteMode.UNDECIDED,
        Int64(0),
    )
end

@inline _stream_is_client(::Stream{IS_CLIENT}) where {IS_CLIENT} = IS_CLIENT

@inline function _require_client_stream(stream::Stream{IS_CLIENT}) where {IS_CLIENT}
    IS_CLIENT || throw(ArgumentError("operation is only valid for client-side HTTP streams"))
    return nothing
end

function _stream_response(stream::Stream)::Response
    resp = stream.response
    resp === nothing && throw(ProtocolError("response has not started yet"))
    return resp::Response
end

function _stream_reader(stream::Stream)::IO
    reader = stream.reader
    reader === nothing && throw(ProtocolError("response body reader is not available"))
    return reader::IO
end

"""
    isaborted(stream) -> Bool

Return `true` when the streamed response terminated in an aborted/error state
that should not be reused as a keep-alive connection.
"""
function isaborted(stream::Stream)::Bool
    response = stream.response
    response === nothing && return false
    return _status_throws(response::Response) &&
           (response.close || headercontains(response, "Connection", "close"))
end

function _client_finish_stream_read!(stream::Stream{true}, suppress_producer_errors::Bool)::Response
    _require_client_stream(stream)
    was_closed = @atomic :acquire stream.read_closed
    was_closed && return _stream_response(stream)
    @atomic :release stream.read_closed = true
    reader = stream.reader
    producer = stream.producer
    try
        if reader !== nothing
            close(reader)
        end
    catch
    end
    if producer !== nothing
        if suppress_producer_errors
            try
                wait(producer)
            catch
            end
        else
            wait(producer)
        end
    end
    if stream.owns_client
        close(stream.client::Client)
    end
    return _stream_response(stream)
end

function _client_start_stream_read!(stream::Stream{true})::Response
    _require_client_stream(stream)
    started = @atomic :acquire stream.started
    started && return _stream_response(stream)
    @atomic :release stream.started = true
    @atomic :release stream.write_closed = true
    request_bytes = take!(stream.request_buffer)
    body_input = isempty(request_bytes) ? nothing : request_bytes
    normalized_body = _normalize_body_input(body_input)
    stream.request_body = normalized_body.body
    stream.request_body_content_length = normalized_body.content_length
    meta = stream.message
    req = Request{AbstractBody}(
        meta.method,
        meta.target,
        meta.headers,
        meta.trailers,
        stream.request_body,
        meta.host,
        stream.request_body_content_length,
        meta.proto_major,
        meta.proto_minor,
        meta.close,
        get_request_context(meta),
    )
    incoming = _do_incoming!(
        nothing,
        stream.client::Client,
        (stream.parsed::_URLParts).address,
        req,
        (stream.parsed::_URLParts).secure,
        (stream.parsed::_URLParts).server_name,
        stream.protocol,
        stream.redirect ? (stream.redirect_policy::_RedirectPolicy) : _redirect_policy(stream.client::Client, 0),
        stream.retry_controller,
        stream.proxy_config,
        stream.cookies,
        stream.cookiejar,
    )
    resolved_request = incoming.head.request === nothing ? req : incoming.head.request::Request
    stream.response = _finalize_request_response(
        incoming,
        nothing,
        _should_decompress_response(incoming.head.headers, stream.decompress) ? Int64(-1) : incoming.head.content_length,
        resolved_request,
        (stream.parsed::_URLParts).url,
    )
    reader, producer = _response_body_reader(incoming, stream.decompress)
    stream.reader = reader
    stream.producer = producer
    return stream.response::Response
end

"""
    startread(stream)

Begin the readable side of `stream`.

For client streams, this finalizes request writes if needed, executes the HTTP
exchange, and returns the response metadata without buffering the response
body. Subsequent reads on `stream` consume the response body.

For server streams, this returns request metadata only. The request body stays
attached to `stream` itself, so handlers should read it with `read(stream)` or
`readbytes!(stream, ...)`.
"""
startread(stream::Stream{true}) = _client_start_stream_read!(stream)
startread(stream::Stream{false}) = _server_startread(stream)

isopen(stream::Stream{true}) = !(@atomic :acquire stream.read_closed) || !(@atomic :acquire stream.write_closed)
isopen(stream::Stream{false}) = _server_isopen(stream)

function write(stream::Stream{true}, data::Vector{UInt8})::Int
    (@atomic :acquire stream.started) && throw(ArgumentError("cannot write request body after response reading has started"))
    (@atomic :acquire stream.write_closed) && throw(ArgumentError("request body writes are closed"))
    return write(stream.request_buffer, data)
end
write(stream::Stream{false}, data::Vector{UInt8}) = _server_write(stream, data)

function write(stream::Stream{true}, data::StridedVector{UInt8})::Int
    (@atomic :acquire stream.started) && throw(ArgumentError("cannot write request body after response reading has started"))
    (@atomic :acquire stream.write_closed) && throw(ArgumentError("request body writes are closed"))
    return write(stream.request_buffer, data)
end
write(stream::Stream{false}, data::StridedVector{UInt8}) = _server_write(stream, data)

function write(stream::Stream{true}, data::AbstractVector{UInt8})::Int
    (@atomic :acquire stream.started) && throw(ArgumentError("cannot write request body after response reading has started"))
    (@atomic :acquire stream.write_closed) && throw(ArgumentError("request body writes are closed"))
    return write(stream.request_buffer, Vector{UInt8}(data))
end
write(stream::Stream{false}, data::AbstractVector{UInt8}) = _server_write(stream, data)

function _client_stream_write(stream::Stream{true}, data::AbstractString)::Int
    (@atomic :acquire stream.started) && throw(ArgumentError("cannot write request body after response reading has started"))
    (@atomic :acquire stream.write_closed) && throw(ArgumentError("request body writes are closed"))
    return write(stream.request_buffer, String(data))
end

write(stream::Stream{true}, data::AbstractString)::Int = _client_stream_write(stream, data)
write(stream::Stream{true}, data::Union{String,SubString{String}})::Int = _client_stream_write(stream, data)
write(stream::Stream{false}, data::AbstractString) = _server_write(stream, data)
write(stream::Stream{false}, data::Union{String,SubString{String}}) = _server_write(stream, data)

function closewrite(stream::Stream{true})
    @atomic :release stream.write_closed = true
    return nothing
end
closewrite(stream::Stream{false}) = _server_closewrite(stream)

function readbytes!(stream::Stream{true}, dest::AbstractVector{UInt8}, nb::Integer=length(dest))
    nb >= 0 || throw(ArgumentError("nb must be >= 0"))
    _client_start_stream_read!(stream)
    n = readbytes!(_stream_reader(stream), dest, nb)
    n == 0 && _client_finish_stream_read!(stream, false)
    return n
end
readbytes!(stream::Stream{false}, dest::AbstractVector{UInt8}, nb::Integer=length(dest)) = _server_readbytes!(stream, dest, nb)

function read(stream::Stream{true})::Vector{UInt8}
    _client_start_stream_read!(stream)
    bytes = read(_stream_reader(stream))
    _client_finish_stream_read!(stream, false)
    return bytes
end
read(stream::Stream{false}) = _server_read(stream)

function read(stream::Stream, ::Type{String})::String
    return String(read(stream))
end

function eof(stream::Stream{true})::Bool
    _client_start_stream_read!(stream)
    done = eof(_stream_reader(stream))
    done && _client_finish_stream_read!(stream, false)
    return done
end
eof(stream::Stream{false}) = _server_eof(stream)

"""
    closeread(stream) -> Response

Close the readable side of `stream` and return its response metadata.

If the response body has already been fully consumed, this is effectively a
no-op. If unread response bytes remain, the underlying client connection is not
reused.
"""
function closeread(stream::Stream{true})
    _client_start_stream_read!(stream)
    return _client_finish_stream_read!(stream, true)
end
closeread(stream::Stream{false}) = _server_closeread(stream)

function close(stream::Stream{true})
    try
        closewrite(stream)
    catch
    end
    try
        closeread(stream)
    catch
    end
    return nothing
end
close(stream::Stream{false}) = _server_close(stream)

"""
    open(method, url, headers=Pair{String,String}[]; kwargs...) -> Stream
    open(f, method, url, headers=Pair{String,String}[]; kwargs...)

Create a streaming HTTP client request/response exchange.

The returned `Stream` buffers request writes locally until `startread(stream)`
or the end of the `do` block. Once reading starts, `stream` behaves like a
readable `IO` for the response body. `kwargs` largely mirror `request(...)`,
including `redirect`, `redirect_limit`, `redirect_method`,
`forwardheaders`, `cookies`, `cookiejar`, `decompress`, `basicauth`, `retry`,
`retries`, `retry_non_idempotent`, `retry_if`, `respect_retry_after`,
`retry_bucket`, `client`, `connect_timeout`, `request_timeout`,
`response_header_timeout`, `read_idle_timeout`, `write_idle_timeout`,
`expect_continue_timeout`, `readtimeout`, `require_ssl_verification`, and
`protocol`. `basicauth` accepts
`(username, password)` credentials; explicit `Authorization` headers take
precedence, and URL `userinfo` is only used as a fallback when neither is
provided. As with `request(...)`, automatic retries only occur for replayable
request bodies, `retry_bucket=true` uses the transport's default `RetryBucket`,
and the built-in policy does not automatically retry request
read-timeout/deadline failures. `request_timeout` applies an overall deadline,
`read_idle_timeout` and `write_idle_timeout` bound inactivity between response
and request I/O progress, `response_header_timeout` bounds the wait for
response headers after the request is sent, and deprecated `readtimeout`
behaves like `read_idle_timeout`.

As with `request(...)`, `retry_if` sees request-path failures as
`RequestRetryError` and can inspect the underlying exception via `err.err`.

The `do`-block form closes request writes automatically, closes the readable
side on exit, and returns the final response metadata.

"""
function open(
    method::Union{AbstractString,Symbol},
    url::Union{AbstractString,URI},
    headers=Pair{String,String}[];
    retry::Bool=true,
    retries::Integer=4,
    retry_non_idempotent::Bool=false,
    retry_if=nothing,
    respect_retry_after::Bool=true,
    retry_bucket::Union{Bool,RetryBucket}=true,
    redirect::Bool=true,
    redirect_limit::Union{Nothing,Integer}=nothing,
    redirect_method=nothing,
    forwardheaders::Bool=true,
    proxy=_USE_TRANSPORT_PROXY,
    cookies=true,
    cookiejar::Union{Nothing,CookieJar}=nothing,
    query=nothing,
    decompress::Union{Nothing,Bool}=nothing,
    basicauth=nothing,
    client::Union{Nothing,Client}=nothing,
    connect_timeout::Real=30,
    request_timeout::Real=0,
    response_header_timeout::Real=0,
    read_idle_timeout::Real=0,
    write_idle_timeout::Real=0,
    expect_continue_timeout=nothing,
    readtimeout=nothing,
    copyheaders=nothing,
    pool=nothing,
    canonicalize_headers=nothing,
    detect_content_type=nothing,
    observelayers=nothing,
    retry_delays=nothing,
    retry_check=nothing,
    sslconfig=nothing,
    socket_type_tls=nothing,
    logerrors=nothing,
    logtag=nothing,
    require_ssl_verification::Bool=true,
    protocol::Symbol=:auto
)::Stream
    _handle_client_compat_kwargs(
        copyheaders=copyheaders,
        pool=pool,
        canonicalize_headers=canonicalize_headers,
        detect_content_type=detect_content_type,
        observelayers=observelayers,
        retry_delays=retry_delays,
        retry_check=retry_check,
        sslconfig=sslconfig,
        socket_type_tls=socket_type_tls,
        logerrors=logerrors,
        logtag=logtag,
    )
    parsed = _parse_http_url(url, query)
    req_headers = _normalize_headers_input(headers)
    normalized_cookies = _normalize_cookies_input(cookies)
    _apply_default_accept_encoding!(req_headers, decompress)
    _apply_request_authorization!(req_headers, basicauth, parsed.authorization)
    req_client, owns_client = _client_for_request(client, connect_timeout, require_ssl_verification)
    request_timeout_ns, timeout_config = _resolve_request_timeout_settings(
        request_timeout,
        connect_timeout,
        response_header_timeout,
        read_idle_timeout,
        write_idle_timeout,
        expect_continue_timeout,
        readtimeout,
    )
    retry_controller = _retry_controller(req_client, retry, retries, retry_non_idempotent, retry_if, respect_retry_after, retry_bucket)
    client === nothing || proxy === _USE_TRANSPORT_PROXY || throw(ArgumentError("proxy override is not supported when passing an explicit Client"))
    proxy_config = _proxy_config_for_request(req_client, proxy)
    effective_cookiejar = _effective_cookiejar(client, cookiejar)
    stream = Stream(
        _method_upper(String(method)),
        parsed,
        req_headers,
        req_client,
        owns_client;
        proxy_config=proxy_config,
        cookies=normalized_cookies,
        cookiejar=effective_cookiejar,
        redirect=redirect,
        protocol=protocol,
        decompress=decompress,
        request_timeout_ns=request_timeout_ns,
        timeout_config=timeout_config,
        retry_controller=retry_controller,
        redirect_policy=_redirect_policy(req_client, redirect_limit, redirect_method, forwardheaders),
    )
    return stream
end

function open(
    f::Function,
    method::Union{AbstractString,Symbol},
    url::Union{AbstractString,URI},
    headers=Pair{String,String}[];
    status_exception::Bool=true,
    kwargs...,
)
    stream = open(method, url, headers; kwargs...)
    try
        f(stream)
    catch
        @try_ignore closewrite(stream)
        @try_ignore closeread(stream)
        rethrow()
    finally
        @try_ignore closewrite(stream)
    end
    response = closeread(stream)
    if status_exception && _status_throws(response)
        throw(StatusError(response))
    end
    return response
end
