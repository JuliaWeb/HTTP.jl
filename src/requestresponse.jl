export Header, Headers, Message, Request, Response,
    header, headers, hasheader, headercontains,
    setheader, setheaderifabsent, setheaders!, defaultheader!, appendheader, removeheader,
    canonicalizeheaders, canonicalizeheaders!, mkheaders

# working with headers
headereq(a::String, b::String) = ascii_lc_isequal(a, b)

struct Header
    header::AwsHTTP.HttpHeader
end
Header() = Header(AwsHTTP.HttpHeader("", ""))
Header(name::AbstractString, value::AbstractString) = Header(AwsHTTP.HttpHeader(String(name), String(value)))

function Base.getproperty(x::Header, s::Symbol)
    if s == :name
        return getfield(x, :header).name
    elseif s == :value
        return getfield(x, :header).value
    else
        return getfield(x, s)
    end
end

Base.show(io::IO, h::Header) = print_header(io, h)

@inline _header_name(h::Header) = h.name
@inline _header_name(h::Pair) = String(first(h))
@inline _header_name(h::AwsHTTP.HttpHeader) = h.name
@inline _header_value(h::Header) = h.value
@inline _header_value(h::Pair) = String(last(h))
@inline _header_value(h::AwsHTTP.HttpHeader) = h.value
@inline _header_pair(h) = _header_name(h) => _header_value(h)

Base.first(h::Header) = h.name
Base.last(h::Header) = h.value

mutable struct Headers <: AbstractVector{Pair{String, String}}
    const hdrs::AwsHTTP.HttpHeaders
    function Headers()
        return new(AwsHTTP.http_headers_new())
    end
    Headers(hdrs::AwsHTTP.HttpHeaders) = new(hdrs)
    function Headers(h::AbstractVector{<:Pair})
        hdrs = AwsHTTP.http_headers_new()
        for (k, v) in h
            AwsHTTP.http_headers_add(hdrs, String(k), String(v)) != 0 && aws_throw_error()
        end
        return new(hdrs)
    end
end

abstract type Message end

Base.eltype(::Type{Headers}) = Pair{String, String}
Base.IndexStyle(::Type{Headers}) = IndexLinear()
Base.size(h::Headers) = (AwsHTTP.http_headers_count(h.hdrs),)
Base.length(h::Headers) = AwsHTTP.http_headers_count(h.hdrs)

function Base.getindex(h::Headers, i::Int)
    hdr = AwsHTTP.http_headers_get_index(h.hdrs, i - 1)
    hdr === nothing && throw(BoundsError(h, i))
    return _header_pair(hdr)
end

function Base.setindex!(h::Headers, v::Pair, i::Int)
    len = length(h)
    (i < 1 || i > len) && throw(BoundsError(h, i))
    items = collect(h)
    items[i] = String(v.first) => String(v.second)
    empty!(h)
    addheaders(h, items)
    return h
end

function Base.insert!(h::Headers, i::Int, v::Pair)
    len = length(h)
    (i < 1 || i > len + 1) && throw(BoundsError(h, i))
    items = collect(h)
    insert!(items, i, String(v.first) => String(v.second))
    empty!(h)
    addheaders(h, items)
    return h
end

function Base.push!(h::Headers, v::Pair)
    addheader(h, v)
    return h
end

function Base.push!(h::Headers, v::Header)
    addheader(h, v)
    return h
end

Base.Dict(h::Headers) = Dict((_header_pair(h2) for h2 in h))
Base.copy(h::Headers) = mkheaders(h)
Base.convert(::Type{Vector{Pair{String, String}}}, h::Headers) = mkheaders(h)

addheader(headers::Headers, h::Header) = AwsHTTP.http_headers_add_header(headers.hdrs, h.header) != 0 && aws_throw_error()
addheader(headers::Headers, h::AwsHTTP.HttpHeader) = AwsHTTP.http_headers_add_header(headers.hdrs, h) != 0 && aws_throw_error()
addheader(headers::Headers, h::Pair) = AwsHTTP.http_headers_add(headers.hdrs, String(h.first), String(h.second)) != 0 && aws_throw_error()
addheader(headers::Headers, k, v) = AwsHTTP.http_headers_add(headers.hdrs, String(k), String(v)) != 0 && aws_throw_error()
addheaders(headers::Headers, h::Vector{AwsHTTP.HttpHeader}) = AwsHTTP.http_headers_add_array(headers.hdrs, h) != 0 && aws_throw_error()

function addheaders(headers::Headers, h::AbstractVector{<:Pair})
    for (k, v) in h
        addheader(headers, k, v)
    end
end

setheader(headers::Headers, k, v) = AwsHTTP.http_headers_set(headers.hdrs, String(k), String(v)) != 0 && aws_throw_error()
setscheme(headers::Headers, scheme) = AwsHTTP.http2_headers_set_request_scheme(headers.hdrs, String(scheme)) != 0 && aws_throw_error()
setauthority(headers::Headers, authority) = AwsHTTP.http2_headers_set_request_authority(headers.hdrs, String(authority)) != 0 && aws_throw_error()

function getheader(headers::Headers, k)
    return AwsHTTP.http_headers_get(headers.hdrs, String(k))
end

hasheader(headers::Headers, k) = AwsHTTP.http_headers_has(headers.hdrs, String(k))

removeheader(headers::Headers, k) = AwsHTTP.http_headers_erase(headers.hdrs, String(k)) != 0 && aws_throw_error()
removeheader(headers::Headers, k, v) = AwsHTTP.http_headers_erase_value(headers.hdrs, String(k), String(v)) != 0 && aws_throw_error()

function Base.deleteat!(h::Headers, i::Int)
    AwsHTTP.http_headers_erase_index(h.hdrs, i - 1) != 0 && aws_throw_error()
    return h
end

function Base.empty!(h::Headers)
    AwsHTTP.http_headers_clear(h.hdrs)
    return h
end

setheaderifabsent(headers, k, v) = !hasheader(headers, k) && setheader(headers, k, v)
setheaderifabsent(m::Message, k, v) = setheaderifabsent(m.headers, k, v)

function setheaders!(headers::Headers, newheaders)
    newheaders === headers && return headers
    if newheaders === nothing
        empty!(headers)
        return headers
    end
    if newheaders isa Headers
        newheaders.hdrs === headers.hdrs && return headers
        items = collect(newheaders)
    elseif newheaders isa AwsHTTP.HttpHeaders
        items = collect(Headers(newheaders))
    else
        items = mkheaders(newheaders)
    end
    empty!(headers)
    addheaders(headers, items)
    return headers
end

setheaders!(m::Message, newheaders) = setheaders!(m.headers, newheaders)

field_name_isequal(a, b) = headereq(String(a), String(b))

Base.getindex(m::Message, k) = header(m, k)

"""
    HTTP.header(::Message, key [, default=""]) -> String

Get header value for `key` (case-insensitive).
"""
header(m::Message, k, d="") = header(m.headers, k, d)
header(h::Headers, k, d="") = (v = getheader(h, String(k)); v === nothing ? d : v)
header(h::AbstractVector{<:Pair}, k, d="") = begin
    for (name, value) in h
        if field_name_isequal(name, k)
            return String(value)
        end
    end
    return d
end

"""
    HTTP.headers(m::Message, key) -> Vector{String}

Get all headers with key `k` or empty if none.
"""
headers(h::Headers, k) = [_header_value(h2) for h2 in h if field_name_isequal(_header_name(h2), k)]
headers(h::AbstractVector{<:Pair}, k) = [String(v) for (name, v) in h if field_name_isequal(name, k)]
headers(m::Message, k) = headers(m.headers, k)

"""
    HTTP.hasheader(::Message, key) -> Bool

Does header value for `key` exist (case-insensitive)?
"""
hasheader(m::Message, k) = header(m, k) != ""
hasheader(m::Message, k, v) = field_name_isequal(header(m, k), v)

"""
    HTTP.headercontains(::Message, key, value) -> Bool

Does the header for `key` (interpreted as comma-separated list) contain `value` (case-insensitive)?
"""
headercontains(m::Message, k, v) = any(field_name_isequal.(strip.(split(header(m, k), ",")), v))
headercontains(h::Headers, k, v) = any(field_name_isequal.(strip.(split(header(h, k), ",")), v))
headercontains(h::AbstractVector{<:Pair}, k, v) = any(field_name_isequal.(strip.(split(header(h, k), ",")), v))

"""
    HTTP.setheader(::Message, key => value)

Set header `value` for `key` (case-insensitive).
"""
setheader(m::Message, v) = setheader(m.headers, v)
setheader(h::Headers, v::Header) = setheader(h, v.name, v.value)
setheader(h::Headers, v::Pair) = setheader(h, String(v.first), String(v.second))
function setheader(h::AbstractVector{<:Pair}, v::Pair)
    key = String(v.first)
    value = String(v.second)
    for i in eachindex(h)
        if field_name_isequal(h[i].first, key)
            h[i] = key => value
            return h
        end
    end
    push!(h, key => value)
    return h
end

appendheader(m::Message, v) = appendheader(m.headers, v)
appendheader(h::Headers, v::Header) = addheader(h, v)
appendheader(h::Headers, v::Pair) = addheader(h, String(v.first), String(v.second))
function appendheader(h::AbstractVector{<:Pair}, v::Pair)
    push!(h, String(v.first) => String(v.second))
    return h
end

removeheader(m::Message, k) = removeheader(m.headers, k)
removeheader(m::Message, k, v) = removeheader(m.headers, k, v)
function removeheader(h::AbstractVector{<:Pair}, k)
    key = String(k)
    filter!(kv -> !field_name_isequal(kv.first, key), h)
    return h
end
function removeheader(h::AbstractVector{<:Pair}, k, v)
    key = String(k)
    val = String(v)
    filter!(kv -> !(field_name_isequal(kv.first, key) && field_name_isequal(kv.second, val)), h)
    return h
end

"""
    defaultheader!(::Message, key => value)

Set header `value` in message for `key` if it is not already set.
"""
function defaultheader!(m, v::Pair)
    if header(m, first(v), nothing) === nothing
        setheader(m, v)
    end
    return
end

function canonicalizeheaders!(h::Headers)
    items = [(_header_name(h2), _header_value(h2)) for h2 in h]
    for i in length(h):-1:1
        deleteat!(h, i)
    end
    for (k, v) in items
        addheader(h, tocameldash(k), v)
    end
    return h
end

canonicalizeheaders(h::AbstractVector{<:Pair}) =
    [tocameldash(String(k)) => String(v) for (k, v) in h]

mkheaders(::Nothing) = Pair{String, String}[]
mkheaders(h::Headers) = [_header_pair(h2) for h2 in h]
mkheaders(h::AbstractVector{Header}) = begin
    headers = Pair{String, String}[]
    for head in h
        push!(headers, _header_pair(head))
    end
    return headers
end
mkheaders(h::AbstractVector{<:Pair}) = [String(k) => String(v) for (k, v) in h]
function mkheaders(h)
    headers = Pair{String, String}[]
    for (k, v) in h
        push!(headers, String(k) => String(v))
    end
    return headers
end

function mkreqheaders(h, copyheaders::Bool)
    if h === nothing
        return Pair{String, String}[]
    elseif h isa AbstractVector{<:Pair} && !copyheaders
        return h
    else
        return mkheaders(h)
    end
end

function sync_headers!(dest::AbstractVector{<:Pair}, src::Headers)
    empty!(dest)
    for h in src
        push!(dest, _header_pair(h))
    end
    return dest
end

# request/response

mutable struct InputStream
    bodyref::Any
    bodylen::Int64
    InputStream() = new(nothing, 0)
end

ischunked(is::InputStream) = is.bodylen < 0 && is.bodyref !== nothing

const RequestBodyTypes = Union{AbstractString, AbstractVector{UInt8}, IO, AbstractDict, NamedTuple, Form, Nothing}
const DEFAULT_IO_CHUNK_SIZE = 64 * 1024

struct IOChunkedBody{T<:IO}
    io::T
    chunk_size::Int
    buf::Vector{UInt8}
end

IOChunkedBody(io::IO; chunk_size::Int=DEFAULT_IO_CHUNK_SIZE) =
    IOChunkedBody{typeof(io)}(io, chunk_size, Vector{UInt8}(undef, chunk_size))

function Base.iterate(it::IOChunkedBody, state=nothing)
    eof(it.io) && return nothing
    n = readbytes!(it.io, it.buf, it.chunk_size)
    n == 0 && return nothing
    return view(it.buf, 1:n), nothing
end

const OBSERVELAYER_NAMES = (:messagelayer, :redirectlayer, :retrylayer, :connectionlayer, :streamlayer)

function _init_observations!(context::Dict{Symbol, Any})
    for name in OBSERVELAYER_NAMES
        context[Symbol(name, "_count")] = 0
        context[Symbol(name, "_duration_ms")] = 0.0
    end
    return context
end

function _record_layer!(context::Dict{Symbol, Any}, name::Symbol, started::Float64)
    cntkey = Symbol(name, "_count")
    durkey = Symbol(name, "_duration_ms")
    context[cntkey] = Base.get(() -> 0, context, cntkey) + 1
    context[durkey] = Base.get(() -> 0.0, context, durkey) + (time() - started) * 1000
    return
end

function setinputstream!(m::Message, body)
    AwsHTTP.http_message_set_body_stream(getfield(m, :msg), nothing)
    m.inputstream = nothing
    body === nothing && return
    is = InputStream()
    if (body isa AbstractVector{UInt8}) || (body isa AbstractString)
        is.bodyref = body
        is.bodylen = sizeof(body)
    elseif body isa Union{AbstractDict, NamedTuple}
        is.bodyref = URIs.escapeuri(body)
        is.bodylen = sizeof(is.bodyref)
    elseif body isa IOStream
        isopen(body) || throw(ArgumentError("request body IOStream is closed"))
        is.bodyref = read(body)
        is.bodylen = sizeof(is.bodyref)
    elseif body isa Form
        is.bodyref = read(body)
        is.bodylen = sizeof(is.bodyref)
    elseif body isa IO
        bytes = readavailable(body)
        while !eof(body)
            append!(bytes, readavailable(body))
        end
        is.bodyref = bytes
        is.bodylen = sizeof(is.bodyref)
    elseif Base.isiterable(typeof(body))
        # chunked request body; any kind of iterable where elements are RequestBodyTypes
        is.bodyref = body
        is.bodylen = -1
    else
        throw(ArgumentError("request body must be a string, vector of UInt8, NamedTuple, AbstractDict, HTTP.Form, IO, or an iterable of those"))
    end
    setfield!(m, :inputstream, is)
    if is.bodylen > 0
        # Wrap body in IOBuffer so the H1 encoder's readbytes! works
        AwsHTTP.http_message_set_body_stream(getfield(m, :msg), IOBuffer(is.bodyref))
        if body isa Union{AbstractDict, NamedTuple}
            setheaderifabsent(m.headers, "content-type", "application/x-www-form-urlencoded")
        elseif body isa Form
            setheaderifabsent(m.headers, "content-type", content_type(body))
        end
        setheader(m.headers, "content-length", string(is.bodylen))
    end
    return
end


mutable struct Request <: Message
    msg::AwsHTTP.HttpMessage
    inputstream::Union{Nothing, InputStream} # used for outgoing request body
    # only set in server-side request handlers
    body::Union{Nothing, Vector{UInt8}}
    trailers::Union{Nothing, Headers}
    context::Dict{Symbol, Any}
    route::Union{Nothing, String}
    params::Union{Nothing, Dict{String, String}}
    cookies::Any # actually Union{Nothing, Vector{Cookie}}

    function Request(method, path, headers=nothing, body=nothing, http2::Bool=false; context=nothing)
        msg = http2 ?
          AwsHTTP.http2_message_new_request() :
          AwsHTTP.http_message_new_request()
        AwsHTTP.http_message_set_request_method(msg, String(method)) != 0 && aws_throw_error()
        AwsHTTP.http_message_set_request_path(msg, String(path)) != 0 && aws_throw_error()
        msg_headers = AwsHTTP.http_message_get_headers(msg)
        if headers !== nothing
            src_headers = headers isa AbstractVector{<:Pair} ? headers : mkheaders(headers)
            for (k, v) in src_headers
                AwsHTTP.http_headers_add(msg_headers, String(k), String(v)) != 0 && aws_throw_error()
            end
        end
        req = new(msg)
        req.body = nothing
        req.inputstream = nothing
        req.trailers = nothing
        req.context = context === nothing ? Dict{Symbol, Any}() : context
        req.route = nothing
        req.params = nothing
        req.cookies = nothing
        body !== nothing && setinputstream!(req, body)
        return req
    end
end

# compatibility: 6-arg version for callers that still pass allocator
Request(method, path, headers, body, http2::Bool, _allocator; context=nothing) =
    Request(method, path, headers, body, http2; context=context)

getrequest(req::Request) = req

function observelayer(f)
    function observation(req_or_stream; kw...)
        req = getrequest(req_or_stream)
        nm = nameof(f)
        start_time = time()
        ctx = req.context
        ctx[Symbol(nm, "_count")] = Base.get(() -> 0, ctx, Symbol(nm, "_count")) + 1
        try
            return f(req_or_stream; kw...)
        finally
            ctx[Symbol(nm, "_duration_ms")] =
                Base.get(() -> 0.0, ctx, Symbol(nm, "_duration_ms")) + (time() - start_time) * 1000
        end
    end
end

function Base.getproperty(x::Request, s::Symbol)
    if s == :method
        return AwsHTTP.http_message_get_request_method(getfield(x, :msg))
    elseif s == :path || s == :target
        return AwsHTTP.http_message_get_request_path(getfield(x, :msg))
    elseif s == :uri
        path = AwsHTTP.http_message_get_request_path(getfield(x, :msg))
        return path === nothing ? URI("/") : URI(path)
    elseif s == :headers
        return Headers(AwsHTTP.http_message_get_headers(getfield(x, :msg)))
    elseif s == :version
        v = AwsHTTP.http_message_get_protocol_version(getfield(x, :msg))
        return v == AwsHTTP.HttpVersion.HTTP_2 ? HTTPVersion(2, 0) : HTTPVersion(1, 1)
    else
        return getfield(x, s)
    end
end

function Base.setproperty!(x::Request, s::Symbol, v)
    if s == :method
        AwsHTTP.http_message_set_request_method(getfield(x, :msg), String(v)) != 0 && aws_throw_error()
    elseif s == :path
        AwsHTTP.http_message_set_request_path(getfield(x, :msg), String(v)) != 0 && aws_throw_error()
    elseif s == :headers
        setheaders!(x, v)
    else
        setfield!(x, s, v)
    end
end

function print_header(io, h)
    key = _header_name(h)
    val = _header_value(h)
    if headereq(key, "authorization")
        write(io, string(key, ": ", "******", "\r\n"))
        return
    elseif headereq(key, "proxy-authorization")
        write(io, string(key, ": ", "******", "\r\n"))
    elseif headereq(key, "cookie")
        write(io, string(key, ": ", "******", "\r\n"))
        return
    elseif headereq(key, "set-cookie")
        write(io, string(key, ": ", "******", "\r\n"))
    else
        write(io, string(key, ": ", val, "\r\n"))
        return
    end
end

function print_request(io, method, version, path, headers, body)
    write(io, "\"\"\"\n")
    write(io, string(method, " ", path, " "))
    if version isa HTTPVersion
        write(io, version)
    else
        write(io, "HTTP/", string(version))
    end
    write(io, "\r\n")
    for h in headers
        print_header(io, h)
    end
    write(io, "\r\n")
    body !== nothing ? write(io, body) : write(io, "[request body streamed]")
    write(io, "\n\"\"\"\n")
    return
end

function getbody(r::Message)
    if isdefined(r, :inputstream) && r.inputstream !== nothing
        return r.inputstream.bodyref
    end
    return r.body
end

print_request(io::IO, r::Request) = print_request(io, r.method, r.version, r.path, r.headers, getbody(r))

function Base.show(io::IO, r::Request)
    println(io, "HTTP.Request:")
    print_request(io, r)
end

method(r::Request) = r.method
target(r::Request) = r.path
headers(r::Request) = r.headers
body(r::Request) = r.body

mutable struct RequestMetrics
    request_body_length::Int
    response_body_length::Int
    nretries::Int
    stream_metrics::Union{Nothing, AwsHTTP.HttpStreamMetrics}
end

RequestMetrics() = RequestMetrics(0, 0, 0, nothing)

mutable struct Response <: Message
    msg::AwsHTTP.HttpMessage
    inputstream::Union{Nothing, InputStream}
    body::Union{Nothing, Vector{UInt8}} # only set for client-side response body when no user-provided response_body
    trailers::Union{Nothing, Headers}
    metrics::RequestMetrics
    request::Union{Request, Nothing}

    function Response(status::Integer, headers, body, http2::Bool=false)
        msg = http2 ?
            AwsHTTP.http2_message_new_response() :
            AwsHTTP.http_message_new_response()
        AwsHTTP.http_message_set_response_status(msg, Int(status)) != 0 && aws_throw_error()
        msg_headers = AwsHTTP.http_message_get_headers(msg)
        if headers !== nothing
            src_headers = headers isa AbstractVector{<:Pair} ? headers : mkheaders(headers)
            for (k, v) in src_headers
                AwsHTTP.http_headers_add(msg_headers, String(k), String(v)) != 0 && aws_throw_error()
            end
        end
        resp = new(msg)
        resp.body = nothing
        resp.inputstream = nothing
        resp.trailers = nothing
        resp.metrics = RequestMetrics()
        resp.request = nothing
        if body !== nothing
            setinputstream!(resp, body)
        else
            if !hasheader(resp.headers, "content-length") && !hasheader(resp.headers, "transfer-encoding")
                setheader(resp.headers, "content-length" => "0")
            end
        end
        return resp
    end
    Response() = new(AwsHTTP.http_message_new_response(), nothing, nothing, nothing, RequestMetrics(), nothing)
end

# compatibility: 5-arg version for callers that still pass allocator
Response(status::Integer, headers, body, http2::Bool, _allocator) =
    Response(status, headers, body, http2)

Response(status::Integer, body) = Response(status, nothing, Vector{UInt8}(string(body)))
Response(status::Integer) = Response(status, nothing, nothing)

getresponse(r::Response) = r

function _head_response!(resp::Response)
    setinputstream!(resp, nothing)
    hasheader(resp.headers, "transfer-encoding") && removeheader(resp.headers, "transfer-encoding")
    setheader(resp.headers, "content-length" => "0")
    return
end

bodylen(m::Message) = isdefined(m, :inputstream) && m.inputstream !== nothing ? m.inputstream.bodylen : 0

function bodylen(r::Response)
    if isdefined(r, :inputstream) && r.inputstream !== nothing
        return r.inputstream.bodylen
    end
    return r.metrics.response_body_length
end

function Base.getproperty(x::Response, s::Symbol)
    if s == :status
        return AwsHTTP.http_message_get_response_status(getfield(x, :msg))
    elseif s == :headers
        return Headers(AwsHTTP.http_message_get_headers(getfield(x, :msg)))
    elseif s == :version
        v = AwsHTTP.http_message_get_protocol_version(getfield(x, :msg))
        return v == AwsHTTP.HttpVersion.HTTP_2 ? HTTPVersion(2, 0) : HTTPVersion(1, 1)
    else
        return getfield(x, s)
    end
end

function Base.setproperty!(x::Response, s::Symbol, v)
    if s == :status
        AwsHTTP.http_message_set_response_status(getfield(x, :msg), Int(v)) != 0 && aws_throw_error()
    elseif s == :headers
        setheaders!(x, v)
    else
        setfield!(x, s, v)
    end
end

function print_response(io, status, version, headers, body)
    write(io, "\"\"\"\n")
    if version isa HTTPVersion
        write(io, version)
    else
        write(io, "HTTP/", string(version))
    end
    write(io, " ", string(status), "\r\n")
    for h in headers
        print_header(io, h)
    end
    write(io, "\r\n")
    body !== nothing ? write(io, body) : write(io, "[response body streamed]")
    write(io, "\n\"\"\"\n")
    return
end

print_response(io::IO, r::Response) = print_response(io, r.status, r.version, r.headers, r.body)

function Base.show(io::IO, r::Response)
    println(io, "HTTP.Response:")
    print_response(io, r)
end

status(r::Response) = r.status
headers(r::Response) = r.headers
body(r::Response) = r.body

"""
    issafe(::Request)

https://tools.ietf.org/html/rfc7231#section-4.2.1
"""
issafe(r::Request) = issafe(r.method)
issafe(method::String) = method in ("GET", "HEAD", "OPTIONS", "TRACE")

"""
    iserror(::Response)

Does this `Response` have an error status?
"""
iserror(r::Response) = iserror(r.status)
iserror(status::Integer) = status != 0 && status != 100 && status != 101 &&
                          (status < 200 || status >= 300) && !isredirect(status)

"""
    isidempotent(::Request)

https://tools.ietf.org/html/rfc7231#section-4.2.2
"""
isidempotent(r::Request) = isidempotent(r.method)
isidempotent(method::String) = issafe(method) || method in ("PUT", "DELETE")

"""
    isredirect(::Response)

Does this `Response` have a redirect status?
"""
isredirect(r::Response) = isredirect(r.status)
isredirect(status::Integer) = status in (301, 302, 303, 307, 308)

Forms.parse_multipart_form(m::Message) = parse_multipart_form(getheader(m.headers, "content-type"), m.body)
