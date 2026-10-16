# Streaming HTTP client API built on top of the shared client execution path.
export startread
export closeread

import Base: bytesavailable, close, closewrite, eof, isopen, read, readavailable, readbytes!, unsafe_write, write

function _client_stream_request(
    method::Union{AbstractString,Symbol},
    parsed::_URLParts,
    headers::Headers,
    request_timeout_ns::Int64,
    timeout_config::Union{Nothing,_RequestTimeoutConfig},
    context::Union{Nothing,RequestContext}=nothing,
)::Request{EmptyBody}
    ctx = context === nothing ? RequestContext() : context::RequestContext
    _apply_request_timeout_settings!(ctx, request_timeout_ns, timeout_config)
    return Request{EmptyBody}(
        String(method),
        parsed.target,
        copy(headers),
        Headers(),
        EmptyBody(),
        parsed.host_header,
        Int64(0),
        UInt8(1),
        UInt8(1),
        false,
        ctx,
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
    context::Union{Nothing,RequestContext}=nothing,
)
    request_timeout_ns >= 0 || throw(ArgumentError("request_timeout_ns must be >= 0"))
    request = _client_stream_request(
        method,
        parsed,
        headers,
        Int64(request_timeout_ns),
        timeout_config,
        context,
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
        false,
        _ServerStreamWriteMode.UNDECIDED,
        Int64(0),
        false,
        nothing,
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

Return `true` when the response on a client `stream` ended in an error, so its
connection cannot be reused.
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
    @try_ignore begin
        if reader !== nothing
            close(reader)
        end
    end
    if producer !== nothing
        if suppress_producer_errors
            @try_ignore begin
                wait(producer)
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
    incoming = try
        _do_incoming!(
            nothing,
            stream.client::Client,
            (stream.parsed::_URLParts).address,
            req,
            (stream.parsed::_URLParts).secure,
            nothing,
            stream.protocol,
            stream.redirect ? (stream.redirect_policy::_RedirectPolicy) : _redirect_policy(stream.client::Client, 0),
            stream.retry_controller,
            stream.proxy_config,
            stream.cookies,
            stream.cookiejar,
        )
    catch err
        wrapped = err isa Exception ? _wrap_tls_transport_error(err::Exception) : err
        wrapped === err ? rethrow() : throw(wrapped)
    end
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

Start reading from `stream` and return the message head.

On a client stream from [`open`](@ref), this finishes sending the request and
returns the [`Response`](@ref) with its status and headers. On a server stream,
it returns the [`Request`](@ref). Either way, read the body from `stream`
itself, with `read(stream)` or `readbytes!(stream, buf)`.
"""
startread(stream::Stream{true}) = _client_start_stream_read!(stream)
startread(stream::Stream{false}) = _server_startread(stream)

isopen(stream::Stream{true}) = !(@atomic :acquire stream.read_closed) || !(@atomic :acquire stream.write_closed)
isopen(stream::Stream{false}) = _server_isopen(stream)

function unsafe_write(stream::Stream, p::Ptr{UInt8}, n::UInt)::UInt
    n == 0 && return UInt(0)
    data = Vector{UInt8}(undef, Int(n))
    unsafe_copyto!(pointer(data), p, n)
    return UInt(write(stream, data))
end

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

# Base defines write(::IO, ::Base.CodeUnits); without these methods, writing
# codeunits to a Stream is ambiguous (CodeUnits <: DenseVector{UInt8}
# intersects the StridedVector methods above) (#1302).
function write(stream::Stream{true}, data::Base.CodeUnits{UInt8})::Int
    (@atomic :acquire stream.started) && throw(ArgumentError("cannot write request body after response reading has started"))
    (@atomic :acquire stream.write_closed) && throw(ArgumentError("request body writes are closed"))
    return write(stream.request_buffer, data)
end
write(stream::Stream{false}, data::Base.CodeUnits{UInt8}) = _server_write(stream, data)

function write(stream::Stream{true}, data::AbstractVector{UInt8})::Int
    (@atomic :acquire stream.started) && throw(ArgumentError("cannot write request body after response reading has started"))
    (@atomic :acquire stream.write_closed) && throw(ArgumentError("request body writes are closed"))
    return write(stream.request_buffer, Vector{UInt8}(data))
end
write(stream::Stream{false}, data::AbstractVector{UInt8}) = _server_write(stream, data)

# Strings are handled via unsafe_write instead of write(::Stream, ::AbstractString)
# methods: Base's generic `write(io::IO, s::Union{String, SubString{String}})`
# funnels through unsafe_write, and extending `write` for string types on a new
# IO type invalidates every abstractly-inferred `write(::IO, ::String)` call
# site in the ecosystem (measured: ~1380 invalidated instances at `using` time).
function Base.unsafe_write(stream::Stream{true}, p::Ptr{UInt8}, n::UInt)::UInt
    n == 0 && return UInt(0)
    (@atomic :acquire stream.started) && throw(ArgumentError("cannot write request body after response reading has started"))
    (@atomic :acquire stream.write_closed) && throw(ArgumentError("request body writes are closed"))
    return unsafe_write(stream.request_buffer, p, n)
end

function Base.unsafe_write(stream::Stream{false}, p::Ptr{UInt8}, n::UInt)::UInt
    n == 0 && return UInt(0)
    data = Vector{UInt8}(undef, Int(n))
    GC.@preserve data unsafe_copyto!(pointer(data), p, n)
    return UInt(_server_write(stream, data))
end

# The byte-I/O primitive: Base's fallbacks for `write(io, ::AbstractString)`
# and `write(io, ::Char)` bottom out in `write(io, ::UInt8)`, so without this
# generic strings throw "does not support byte I/O".
function write(stream::Stream{true}, b::UInt8)::Int
    (@atomic :acquire stream.started) && throw(ArgumentError("cannot write request body after response reading has started"))
    (@atomic :acquire stream.write_closed) && throw(ArgumentError("request body writes are closed"))
    return write(stream.request_buffer, b)
end
write(stream::Stream{false}, b::UInt8) = _server_write(stream, UInt8[b])

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

function read(stream::Stream{true}, ::Type{UInt8})::UInt8
    _client_start_stream_read!(stream)
    return read(_stream_reader(stream), UInt8)
end

function readavailable(stream::Stream{true})::Vector{UInt8}
    _client_start_stream_read!(stream)
    return readavailable(_stream_reader(stream))
end

function bytesavailable(stream::Stream{true})::Int
    (@atomic :acquire stream.started) || return 0
    reader = stream.reader
    reader === nothing && return 0
    return bytesavailable(reader::IO)
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

Stop reading from `stream` and return its [`Response`](@ref): the response
received on a client stream, or the response being written on a server stream.
Body bytes that were not read are discarded, and the connection is then closed
instead of reused.
"""
function closeread(stream::Stream{true})
    _client_start_stream_read!(stream)
    return _client_finish_stream_read!(stream, true)
end
closeread(stream::Stream{false}) = _server_closeread(stream)

function close(stream::Stream{true})
    @try_ignore begin
        closewrite(stream)
    end
    @try_ignore begin
        closeread(stream)
    end
    return nothing
end
close(stream::Stream{false}) = _server_close(stream)

"""
    open(method, url, headers=[]; kwargs...) -> Stream
    open(f, method, url, headers=[]; status_exception=true, kwargs...) -> Response

Send a request and stream its body and response through a [`Stream`](@ref).
Write the request body to the stream, call [`startread`](@ref) to finish the
request and get the response status and headers, then read the response body
from the stream like any `IO`.

With a function `f`, `open` calls `f(stream)`, finishes the exchange, and
returns the final [`Response`](@ref), not the value of `f`. It throws a
[`StatusError`](@ref) for a failing response unless `status_exception = false`.
Without `f`, close the stream with `closewrite` and [`closeread`](@ref) when you
are done.

`open` follows redirects, retries, decompresses, and applies timeouts like
[`request`](@ref), and takes its keywords except `body`, `response_stream`,
`sse_callback`, `trace`, `verbose`, and the size limits.

```julia
buf = IOBuffer()
response = HTTP.open("GET", "https://example.com") do stream
    write(buf, stream)  # copy the body as it arrives
end
```
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
    context::Union{Nothing,RequestContext}=nothing,
    connect_timeout::Union{Nothing,Real}=nothing,
    request_timeout::Real=0,
    response_header_timeout::Real=0,
    read_idle_timeout::Real=0,
    write_idle_timeout::Real=0,
    expect_continue_timeout=nothing,
    readtimeout=nothing,
    copyheaders::Bool=true,
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
    client === nothing || _check_client_open(client)
    _handle_client_compat_kwargs(
        copyheaders=copyheaders,
        pool=pool,
        detect_content_type=detect_content_type,
        observelayers=observelayers,
        retry_delays=retry_delays,
        retry_check=retry_check,
        sslconfig=sslconfig,
        socket_type_tls=socket_type_tls,
        logerrors=logerrors,
        logtag=logtag,
    )
    # Apply client defaults (per-call wins)
    connect_timeout = _resolve_connect_timeout(client, connect_timeout)
    request_timeout = _client_default_timeout(client, request_timeout, :default_request_timeout)
    response_header_timeout = _client_default_timeout(client, response_header_timeout, :default_response_header_timeout)
    read_idle_timeout = _client_default_timeout(client, read_idle_timeout, :default_read_idle_timeout)
    write_idle_timeout = _client_default_timeout(client, write_idle_timeout, :default_write_idle_timeout)
    if basicauth === nothing && client !== nothing
        basicauth = client.default_basicauth
    end
    merged_query = _merge_client_default_query(client, query)
    parsed = _parse_http_url(url, merged_query)
    req_headers = _normalize_headers_input(headers, copyheaders)
    _apply_client_default_headers!(req_headers, client)
    canonicalize_headers === true && _canonicalize_header_names!(req_headers)
    normalized_cookies = _normalize_cookies_input(cookies)
    _apply_default_accept_encoding!(req_headers, decompress)
    _apply_default_user_agent!(req_headers)
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
        context=context,
    )
    return stream
end

# Positional Client overloads.
open(client::Client, method::Union{AbstractString,Symbol}, url::Union{AbstractString,URI}, headers=Pair{String,String}[]; kwargs...) =
    open(method, url, headers; client=client, kwargs...)

open(f::Function, client::Client, method::Union{AbstractString,Symbol}, url::Union{AbstractString,URI}, headers=Pair{String,String}[]; kwargs...) =
    open(f, method, url, headers; client=client, kwargs...)

function open(
    f::Function,
    method::Union{AbstractString,Symbol},
    url::Union{AbstractString,URI},
    headers=Pair{String,String}[];
    status_exception::Bool=true,
    kwargs...,
)
    start_ns = Int64(time_ns())
    ctx_kw = get(kwargs, :context, nothing)
    stream = try
        open(method, url, headers; kwargs...)
    catch err
        elapsed_ns = Int64(time_ns()) - start_ns
        if !(err isa CanceledError) && ctx_kw isa RequestContext && canceled(ctx_kw::RequestContext)
            msg = (ctx_kw::RequestContext).cancel_message === nothing ? "request canceled" : (ctx_kw::RequestContext).cancel_message::String
            throw(CanceledError(msg))
        end
        wrapped = err isa Exception ? _wrap_client_transport_error(err::Exception, "request", Int64(0), elapsed_ns) : err
        wrapped === err ? rethrow() : throw(wrapped)
    end
    try
        f(stream)
    catch err
        @try_ignore closewrite(stream)
        @try_ignore closeread(stream)
        elapsed_ns = Int64(time_ns()) - start_ns
        if !(err isa CanceledError) && ctx_kw isa RequestContext && canceled(ctx_kw::RequestContext)
            msg = (ctx_kw::RequestContext).cancel_message === nothing ? "request canceled" : (ctx_kw::RequestContext).cancel_message::String
            throw(CanceledError(msg))
        end
        wrapped = err isa Exception ? _wrap_client_transport_error(err::Exception, "request", Int64(0), elapsed_ns) : err
        wrapped === err ? rethrow() : throw(wrapped)
    finally
        @try_ignore closewrite(stream)
    end
    response = try
        closeread(stream)
    catch err
        elapsed_ns = Int64(time_ns()) - start_ns
        if !(err isa CanceledError) && ctx_kw isa RequestContext && canceled(ctx_kw::RequestContext)
            msg = (ctx_kw::RequestContext).cancel_message === nothing ? "request canceled" : (ctx_kw::RequestContext).cancel_message::String
            throw(CanceledError(msg))
        end
        wrapped = err isa Exception ? _wrap_client_transport_error(err::Exception, "request", Int64(0), elapsed_ns) : err
        wrapped === err ? rethrow() : throw(wrapped)
    end
    if status_exception && _status_throws(response)
        throw(StatusError(response))
    end
    return response
end
