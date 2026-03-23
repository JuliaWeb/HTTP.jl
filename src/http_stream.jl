# Streaming HTTP client API built on top of the shared client execution path.
export startread
export closeread
export open
export isaborted

import Base: close, closewrite, eof, isopen, open, read, readbytes!, write

"""
    Stream <: IO

Client-side request/response stream returned by `HTTP.open`.

Writes append request body bytes until response reading begins. After
`startread(stream)`, reads consume the response body from the underlying
connection using the same redirect/decompression machinery as `request(...)`.
"""
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
    readtimeout::Real,
    retry_controller::Union{Nothing,_RetryController},
)
    readtimeout >= 0 || throw(ArgumentError("readtimeout must be >= 0"))
    return Stream(
        _StreamType.CLIENT,
        String(method),
        parsed,
        headers,
        client,
        owns_client,
        proxy_config,
        cookies,
        cookiejar,
        redirect,
        redirect_policy,
        protocol,
        decompress,
        Float64(readtimeout),
        retry_controller,
        IOBuffer(),
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
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

@inline function _stream_is_client(stream::Stream)::Bool
    return stream.side == _StreamType.CLIENT
end

function _require_client_stream(stream::Stream)::Nothing
    _stream_is_client(stream) && return nothing
    throw(ArgumentError("operation is only valid for client-side HTTP streams"))
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

function _client_finish_stream_read!(stream::Stream; suppress_producer_errors::Bool)::Response
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
        close(stream.client)
    end
    return _stream_response(stream)
end

function _client_start_stream_read!(stream::Stream)::Response
    _require_client_stream(stream)
    started = @atomic :acquire stream.started
    started && return _stream_response(stream)
    @atomic :release stream.started = true
    @atomic :release stream.write_closed = true
    request_bytes = take!(stream.request_buffer)
    body_input = isempty(request_bytes) ? nothing : request_bytes
    normalized_body = _normalize_body_input(body_input)
    req = Request(
        stream.method,
        stream.parsed.target;
        headers=stream.headers,
        body=normalized_body.body,
        host=stream.parsed.address,
        content_length=normalized_body.content_length,
    )
    if stream.readtimeout > 0
        timeout_ns = Int64(round(stream.readtimeout * 1.0e9))
        set_deadline!(req.context, Int64(time_ns()) + timeout_ns)
    end
    incoming = _do_incoming!(
        stream.client,
        stream.parsed.address,
        req;
        secure=stream.parsed.secure,
        server_name=stream.parsed.server_name,
        protocol=stream.protocol,
        redirect_policy=stream.redirect ? stream.redirect_policy : _redirect_policy(stream.client; redirect_limit=0),
        retry_controller=stream.retry_controller,
        proxy_config=stream.proxy_config,
        cookies=stream.cookies,
        cookiejar=stream.cookiejar,
    )
    resolved_request = incoming.head.request === nothing ? req : incoming.head.request::Request
    stream.response = _finalize_request_response(
        incoming,
        nothing,
        _should_decompress_response(incoming.head.headers, stream.decompress) ? Int64(-1) : incoming.head.content_length,
        resolved_request,
        stream.parsed.url,
    )
    reader, producer = _response_body_reader(incoming; decompress=stream.decompress)
    stream.reader = reader
    stream.producer = producer
    return stream.response::Response
end

"""
    startread(stream) -> Response

Finalize request writes if needed, execute the HTTP exchange, and return the
response metadata for `stream` without buffering the response body.

Subsequent reads on `stream` consume the response body. Repeated calls return
the same response object.
"""
function startread(stream::Stream)
    if _stream_is_client(stream)
        return _client_start_stream_read!(stream)
    end
    return _server_startread(stream)
end

function isopen(stream::Stream)::Bool
    if _stream_is_client(stream)
        return !(@atomic :acquire stream.read_closed) || !(@atomic :acquire stream.write_closed)
    end
    return _server_isopen(stream)
end

function write(stream::Stream, data::Vector{UInt8})::Int
    if _stream_is_client(stream)
        (@atomic :acquire stream.started) && throw(ArgumentError("cannot write request body after response reading has started"))
        (@atomic :acquire stream.write_closed) && throw(ArgumentError("request body writes are closed"))
        return write(stream.request_buffer, data)
    end
    return _server_write(stream, data)
end

function write(stream::Stream, data::StridedVector{UInt8})::Int
    if _stream_is_client(stream)
        (@atomic :acquire stream.started) && throw(ArgumentError("cannot write request body after response reading has started"))
        (@atomic :acquire stream.write_closed) && throw(ArgumentError("request body writes are closed"))
        return write(stream.request_buffer, data)
    end
    return _server_write(stream, data)
end

function write(stream::Stream, data::AbstractVector{UInt8})::Int
    if _stream_is_client(stream)
        (@atomic :acquire stream.started) && throw(ArgumentError("cannot write request body after response reading has started"))
        (@atomic :acquire stream.write_closed) && throw(ArgumentError("request body writes are closed"))
        return write(stream.request_buffer, Vector{UInt8}(data))
    end
    return _server_write(stream, data)
end

function write(stream::Stream, data::Union{String,SubString{String}})::Int
    if _stream_is_client(stream)
        (@atomic :acquire stream.started) && throw(ArgumentError("cannot write request body after response reading has started"))
        (@atomic :acquire stream.write_closed) && throw(ArgumentError("request body writes are closed"))
        return write(stream.request_buffer, data)
    end
    return _server_write(stream, data)
end

function closewrite(stream::Stream)
    if _stream_is_client(stream)
        @atomic :release stream.write_closed = true
        return nothing
    end
    return _server_closewrite(stream)
end

function readbytes!(stream::Stream, dest::AbstractVector{UInt8}, nb::Integer=length(dest))
    nb >= 0 || throw(ArgumentError("nb must be >= 0"))
    if _stream_is_client(stream)
        _client_start_stream_read!(stream)
        n = readbytes!(_stream_reader(stream), dest, nb)
        n == 0 && _client_finish_stream_read!(stream; suppress_producer_errors=false)
        return n
    end
    return _server_readbytes!(stream, dest, nb)
end

function read(stream::Stream)::Vector{UInt8}
    if _stream_is_client(stream)
        _client_start_stream_read!(stream)
        bytes = read(_stream_reader(stream))
        _client_finish_stream_read!(stream; suppress_producer_errors=false)
        return bytes
    end
    return _server_read(stream)
end

function read(stream::Stream, ::Type{String})::String
    return String(read(stream))
end

function eof(stream::Stream)::Bool
    if _stream_is_client(stream)
        _client_start_stream_read!(stream)
        done = eof(_stream_reader(stream))
        done && _client_finish_stream_read!(stream; suppress_producer_errors=false)
        return done
    end
    return _server_eof(stream)
end

"""
    closeread(stream) -> Response

Close the readable side of `stream` and return its response metadata.

If the response body has already been fully consumed, this is effectively a
no-op. If unread response bytes remain, the underlying client connection is not
reused.
"""
function closeread(stream::Stream)
    if _stream_is_client(stream)
        _client_start_stream_read!(stream)
        return _client_finish_stream_read!(stream; suppress_producer_errors=true)
    end
    return _server_closeread(stream)
end

function close(stream::Stream)
    if _stream_is_client(stream)
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
    return _server_close(stream)
end

"""
    open(method::Symbol, url, headers=Pair{String,String}[]; kwargs...) -> Stream
    open(f, method::Symbol, url, headers=Pair{String,String}[]; kwargs...)

Create a streaming HTTP client request/response exchange.

The returned `Stream` buffers request writes locally until `startread(stream)`
or the end of the `do` block. Once reading starts, `stream` behaves like a
readable `IO` for the response body. `kwargs` largely mirror `request(...)`,
including `redirect`, `redirect_limit`, `redirect_method`,
`forwardheaders`, `cookies`, `cookiejar`, `decompress`, `basicauth`, `retry`,
`retries`, `retry_non_idempotent`, `retry_if`, `respect_retry_after`,
`retry_bucket`, `client`, `connect_timeout`, `readtimeout`,
`require_ssl_verification`, and `protocol`. `basicauth` accepts
`(username, password)` credentials; explicit `Authorization` headers take
precedence, and URL `userinfo` is only used as a fallback when neither is
provided. As with `request(...)`, automatic retries only occur for replayable
request bodies, `retry_bucket=true` uses the transport's default `RetryBucket`,
and the built-in policy does not automatically retry request
read-timeout/deadline failures.

The `do`-block form closes request writes automatically, closes the readable
side on exit, and returns the final response metadata.

Method is currently a `Symbol` to avoid colliding with Base's file-opening
`open(::AbstractString, ::AbstractString)` methods during precompilation.
"""
function open(
    method::Symbol,
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
    connect_timeout::Real=0,
    readtimeout::Real=0,
    require_ssl_verification::Bool=true,
    protocol::Symbol=:auto,
    kwargs...,
)::Stream
    _validate_request_extra_kwargs(kwargs)
    parsed = _parse_http_url(url; query=query)
    req_headers = _normalize_headers_input(headers)
    normalized_cookies = _normalize_cookies_input(cookies)
    _apply_default_accept_encoding!(req_headers, decompress)
    _apply_request_authorization!(req_headers, basicauth, parsed.authorization)
    req_client, owns_client = _client_for_request(client; connect_timeout=connect_timeout, require_ssl_verification=require_ssl_verification)
    retry_controller = _retry_controller(
        req_client;
        retry=retry,
        retries=retries,
        retry_non_idempotent=retry_non_idempotent,
        retry_if=retry_if,
        respect_retry_after=respect_retry_after,
        retry_bucket=retry_bucket,
    )
    client === nothing || proxy === _USE_TRANSPORT_PROXY || throw(ArgumentError("proxy override is not supported when passing an explicit Client"))
    proxy_config = _proxy_config_for_request(req_client, proxy)
    effective_cookiejar = _effective_cookiejar(client, cookiejar)
    return Stream(
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
        readtimeout=readtimeout,
        retry_controller=retry_controller,
        redirect_policy=_redirect_policy(
            req_client;
            redirect_limit=redirect_limit,
            redirect_method=redirect_method,
            forwardheaders=forwardheaders,
        ),
    )
end

function open(
    f::Function,
    method::Symbol,
    url::Union{AbstractString,URI},
    headers=Pair{String,String}[];
    status_exception::Bool=true,
    kwargs...,
)
    stream = open(method, url, headers; kwargs...)
    callback_error = nothing
    try
        f(stream)
    catch err
        callback_error = err
    finally
        try
            closewrite(stream)
        catch
        end
    end
    response = closeread(stream)
    if status_exception && _status_throws(response)
        throw(StatusError(response))
    end
    callback_error === nothing || throw(callback_error)
    return response
end
