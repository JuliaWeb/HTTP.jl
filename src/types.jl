const Header = Pair{String, String}
const Headers = Vector{Header}

abstract type Message end

const RequestBodyTypes = Union{AbstractString, AbstractVector{UInt8}, IO, AbstractDict, NamedTuple, Nothing}
const Context = Dict{Symbol, Any}

"""
    HTTP.Request(
        method, target, headers=[], body=nobody;
        version=v"1.1", url::URI=URI(), responsebody=nothing, parent=nothing, context=HTTP.Context()
    )

Represents a HTTP Request Message with fields:

- `method::String`
   [RFC7230 3.1.1](https://tools.ietf.org/html/rfc7230#section-3.1.1)

- `target::String`
   [RFC7230 5.3](https://tools.ietf.org/html/rfc7230#section-5.3)

- `version::String`
   [RFC7230 2.6](https://tools.ietf.org/html/rfc7230#section-2.6)

- `headers::HTTP.Headers`
   [RFC7230 3.2](https://tools.ietf.org/html/rfc7230#section-3.2)

- `body::Union{Vector{UInt8}, IO}`
   [RFC7230 3.3](https://tools.ietf.org/html/rfc7230#section-3.3)

- `response`, the `Response` to this `Request`

- `url::URI`, the full URI of the request

- `parent`, the `Response` (if any) that led to this request
  (e.g. in the case of a redirect).
   [RFC7230 6.4](https://tools.ietf.org/html/rfc7231#section-6.4)

- `context`, a `Dict{Symbol, Any}` store used by middleware to share state

"""
mutable struct Request <: Message
    method::String
    version::String
    uri::URI
    _uri::aws_uri
    headers::Headers
    body::RequestBodyTypes
    context::Context

    function Request(method::AbstractString, url, headers=Headers(), body::RequestBodyTypes=nothing, allocator::Ptr{aws_allocator}=default_aws_allocator(), query=nothing, ctx=Context())
        uri_ref = Ref{aws_uri}()
        if url isa AbstractString
            url_str = String(url) * (query === nothing ? "" : ("?" * URIs.escapeuri(query)))
        elseif url isa URI
            url_str = string(url)
        else
            throw(ArgumentError("url must be an AbstractString or URI"))
        end
        GC.@preserve url_str begin
            url_ref = Ref(aws_byte_cursor(sizeof(url_str), pointer(url_str)))
            aws_uri_init_parse(uri_ref, allocator, url_ref)
        end
        _uri = uri_ref[]
        return new(String(method), "", makeuri(_uri), _uri, something(headers, Header[]), body, ctx)
    end
    Request() = new()
end

Base.getproperty(x::Request, s::Symbol) = s == :url || s == :target ? x.uri : getfield(x, s)

function print_header(io, key, val)
    if ascii_lc_isequal(key, "authorization")
        write(io, string(key, ": ", "******", "\r\n"))
        return
    elseif ascii_lc_isequal(key, "proxy-authorization")
        write(io, string(key, ": ", "******", "\r\n"))
    elseif ascii_lc_isequal(key, "cookie")
        write(io, string(key, ": ", "******", "\r\n"))
        return
    elseif ascii_lc_isequal(key, "set-cookie")
        write(io, string(key, ": ", "******", "\r\n"))
    else
        write(io, string(key, ": ", val, "\r\n"))
        return
    end
end

function print_request(io, method, version, path, headers, body)
    write(io, "\"\"\"\n")
    write(io, string(method, " ", path, " HTTP/$version\r\n"))
    for h in headers
        print_header(io, h.first, h.second)
    end
    write(io, "\r\n")
    write(io, string(body))
    write(io, "\n\"\"\"\n")
    return
end

print_request(io::IO, r::Request) = print_request(io, r.method, r.version, r.uri.path, r.headers, r.body)

function Base.show(io::IO, r::Request)
    println(io, "HTTP.Request:")
    print_request(io, r)
end

method(r::Request) = getfield(r, :method)
target(r::Request) = getfield(r, :uri)
url(r::Request) = getfield(r, :url)
headers(r::Request) = getfield(r, :headers)
body(r::Request) = getfield(r, :body)

resource(uri::URI) = string(isempty(uri.path)      ? "/" :     uri.path,
                            !isempty(uri.query)    ? "?" : "", uri.query,
                            !isempty(uri.fragment) ? "#" : "", uri.fragment)

struct StreamMetrics
    send_start_timestamp_ns::Int64
    send_end_timestamp_ns::Int64
    sending_duration_ns::Int64
    receive_start_timestamp_ns::Int64
    receive_end_timestamp_ns::Int64
    receiving_duration_ns::Int64
    stream_id::UInt32
end

mutable struct RequestMetrics
    request_body_length::Int
    response_body_length::Int
    nretries::Int
    stream_metrics::Union{Nothing, StreamMetrics}
end

RequestMetrics() = RequestMetrics(0, 0, 0, nothing)

mutable struct Response <: Message
    status::Int
    version::String
    headers::Headers
    body::Any # IO or Vector{UInt8}
    metrics::RequestMetrics
end

Response(body=UInt8[]) = Response(0, "", Header[], body, RequestMetrics())
Response(status::Integer, body) = Response(status, "", Header[], Vector{UInt8}(string(body)), RequestMetrics())
Response(status::Integer) = Response(status, "", Header[], Vector{UInt8}(), RequestMetrics())

function print_response(io, status, version, headers, body)
    write(io, "\"\"\"\n")
    write(io, string("HTTP/$version ", status, "\r\n"))
    for h in headers
        print_header(io, h.first, h.second)
    end
    write(io, "\r\n")
    write(io, something(body, ""))
    write(io, "\n\"\"\"\n")
    return
end

print_response(io::IO, r::Response) = print_response(io, r.status, r.version, r.headers, r.body)

function Base.show(io::IO, r::Response)
    println(io, "HTTP.Response:")
    print_response(io, r)
end

status(r::Response) = getfield(r, :status)
headers(r::Response) = getfield(r, :headers)
body(r::Response) = getfield(r, :body)

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

"""
    HTTP.hasheader(::Message, key) -> Bool

Does header value for `key` exist (case-insensitive)?
"""
function hasheader end

hasheader(m::Message, k) = hasheader(m.headers, k)
hasheader(h, k) = any(x -> ascii_lc_isequal(x.first, k), h)

"""
    HTTP.header(::Message, key [, default=""]) -> String

Get header value for `key` (case-insensitive).
"""
function header end

header(m::Message, k, d="") = header(m.headers, k, d)
function header(h, key, d="")
    for (k, v) in h
        if ascii_lc_isequal(k, key)
            return v
        end
    end
    return d
end

"""
    HTTP.headers(m::Message, key) -> Vector{String}

Get all headers with key `k` or empty if none
"""
function headers end

headers(m::Message, k) = headers(m.headers, k)
function headers(h, key)
    r = String[]
    for (k, v) in h
        if ascii_lc_isequal(k, key)
            push!(r, v)
        end
    end
    return r
end

"""
    HTTP.headercontains(::Message, key, value) -> Bool

Does the header for `key` (interpreted as comma-separated list) contain `value` (both case-insensitive)?
"""
function headercontains end

headercontains(m::Message, k, v) = headercontains(m.headers, k, v)
function headercontains(h, key, val)
    for (k, v) in h
        if ascii_lc_isequal(k, key)
            return any(x -> ascii_lc_isequal(strip(x), val), split(v, ","))
        end
    end
    return false
end

"""
    HTTP.setheader(::Message, key => value)

Set header `value` for `key` (case-insensitive).
"""
function setheader end

setheader(m::Message, p::Pair) = setheader(m.headers, p.first, p.second)
setheader(m::Message, k, v) = setheader(m.headers, k, v)
function setheader(h, key, val)
    for (i, (k, _)) in enumerate(h)
        if ascii_lc_isequal(k, key)
            h[i] = k => val
            return
        end
    end
    push!(h, key => val)
    return
end

setheader(h, p::Pair) = setheader(h, p.first, p.second)

"""
    HTTP.appendheader(::Message, key => value)

Append a header value to `message.headers`.

If `key` is the same as the previous header, the `value` is [appended to the
value of the previous header with a comma
delimiter](https://stackoverflow.com/a/24502264)

`Set-Cookie` headers are not comma-combined because [cookies often contain
internal commas](https://tools.ietf.org/html/rfc6265#section-3).
"""
function appendheader end

appendheader(m::Message, p::Pair) = appendheader(m.headers, p.first, p.second)
appendheader(m::Message, k, v) = appendheader(m.headers, k, v)
appendheader(h, p::Pair) = appendheader(h, p.first, p.second)
function appendheader(h, key, val)
    if key != "Set-Cookie"
        for (i, (k, v)) in enumerate(h)
            if ascii_lc_isequal(k, key)
                h[i] = k => string(v, ", ", val)
                return
            end
        end
    end
    push!(h, key => val)
    return
end

"""
    HTTP.removeheader(::Message, key)

Remove header for `key` (case-insensitive).
"""
function removeheader end

removeheader(m::Message, k) = removeheader(m.headers, k)
function removeheader(h, k)
    i = findfirst(x -> ascii_lc_isequal(x.first, k), h)
    i === nothing && return
    deleteat!(h, i)
    return
end

const getheader = header