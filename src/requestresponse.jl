# working with headers
headereq(a::String, b::String) = GC.@preserve a b aws_http_header_name_eq(aws_byte_cursor_from_c_str(a), aws_byte_cursor_from_c_str(b))

mutable struct Header
    header::aws_http_header
    Header() = new()
    Header(header::aws_http_header) = new(header)
end

function Base.getproperty(x::Header, s::Symbol)
    if s == :name
        return str(getfield(x, :header).name)
    elseif s == :value
        return str(getfield(x, :header).value)
    else
        return getfield(x, s)
    end
end

Base.show(io::IO, h::Header) = print_header(io, h)

mutable struct Headers <: AbstractVector{Header}
    const ptr::Ptr{aws_http_headers}
    function Headers(allocator=default_aws_allocator())
        x = new(aws_http_headers_new(allocator))
        x.ptr == C_NULL && aws_throw_error()
        return finalizer(_ -> aws_http_headers_release(x.ptr), x)
    end
    # no finalizer in this constructor because whoever called aws_http_headers_new needs to do that
    Headers(ptr::Ptr{aws_http_headers}) = new(ptr)
end

Base.size(h::Headers) = (Int(aws_http_headers_count(h.ptr)),)

function Base.getindex(h::Headers, i::Int)
    header = Header()
    aws_http_headers_get_index(h.ptr, i - 1, FieldRef(header, :header)) != 0 && aws_throw_error()
    return header
end

Base.Dict(h::Headers) = Dict(((h.name, h.value) for h in h))

addheader(headers::Headers, h::Header) = aws_http_headers_add_header(headers.ptr, FieldRef(h, :header)) != 0 && aws_throw_error()
addheader(headers::Headers, k, v) = GC.@preserve k v aws_http_headers_add(headers.ptr, aws_byte_cursor_from_c_str(k), aws_byte_cursor_from_c_str(v)) != 0 && aws_throw_error()
addheaders(headers::Headers, h::Vector{aws_http_header}) = GC.@preserve h aws_http_headers_add_array(headers.ptr, pointer(h), length(h)) != 0 && aws_throw_error()
addheaders(headers::Headers, h::Ptr{aws_http_header}, count::Integer) = aws_http_headers_add_array(headers.ptr, h, count) != 0 && aws_throw_error()

function addheaders(headers::Headers, h::Vector{Pair{String, String}})
    for (k, v) in h
        addheader(headers, k, v)
    end
end

setheader(headers::Headers, k, v) = GC.@preserve k v aws_http_headers_set(headers.ptr, aws_byte_cursor_from_c_str(k), aws_byte_cursor_from_c_str(v)) != 0 && aws_throw_error()
setscheme(headers::Headers, scheme) = GC.@preserve scheme aws_http2_headers_set_request_scheme(headers.ptr, aws_byte_cursor_from_c_str(scheme)) != 0 && aws_throw_error()
setauthority(headers::Headers, authority) = GC.@preserve authority aws_http2_headers_set_request_authority(headers.ptr, aws_byte_cursor_from_c_str(authority)) != 0 && aws_throw_error()

#TODO: struct aws_string *aws_http_headers_get_all(const struct aws_http_headers *headers, struct aws_byte_cursor name);
function getheader(headers::Headers, k)
    out = Ref{aws_byte_cursor}()
    GC.@preserve k out begin
        aws_http_headers_get(headers.ptr, aws_byte_cursor_from_c_str(k), out) != 0 && return nothing
        return str(out[])
    end
end

hasheader(headers::Headers, k) =
    GC.@preserve k aws_http_headers_has(headers.ptr, aws_byte_cursor_from_c_str(k))

removeheader(headers::Headers, k) =
    GC.@preserve k aws_http_headers_erase(headers.ptr, aws_byte_cursor_from_c_str(k)) != 0 && aws_throw_error()

removeheader(headers::Headers, k, v) =
    GC.@preserve k v aws_http_headers_erase_value(headers.ptr, aws_byte_cursor_from_c_str(k), aws_byte_cursor_from_c_str(v)) != 0 && aws_throw_error()

Base.deleteat!(h::Headers, i::Int) = aws_http_headers_erase_index(h.ptr, i - 1) != 0 && aws_throw_error()
Base.empty!(h::Headers) = aws_http_headers_clear(h.ptr) != 0 && aws_throw_error()

setheaderifabsent(headers, k, v) = !hasheader(headers, k) && setheader(headers, k, v)

# request/response
abstract type Message end

mutable struct InputStream
    ptr::Ptr{aws_input_stream}
    bodyref::Any
    bodylen::Int64
    bodycursor::aws_byte_cursor
    InputStream() = new()
end

ischunked(is::InputStream) = is.ptr == C_NULL && is.bodyref !== nothing

const RequestBodyTypes = Union{AbstractString, AbstractVector{UInt8}, IO, AbstractDict, NamedTuple, Nothing}

function InputStream(allocator::Ptr{aws_allocator}, body::RequestBodyTypes)
    is = InputStream()
    if body !== nothing
        if body isa RequestBodyTypes
            if (body isa AbstractVector{UInt8}) || (body isa AbstractString)
                is.bodyref = body
                is.bodycursor = aws_byte_cursor(sizeof(body), pointer(body))
                is.ptr = aws_input_stream_new_from_cursor(allocator, FieldRef(is, :bodycursor))
            elseif body isa Union{AbstractDict, NamedTuple}
                # hold a reference to the request body in order to gc-preserve it
                is.bodyref = URIs.escapeuri(body)
                is.bodycursor = aws_byte_cursor_from_c_str(is.bodyref)
                is.ptr = aws_input_stream_new_from_cursor(allocator, FieldRef(is, :bodycursor))
            elseif body isa IOStream
                is.bodyref = body
                is.ptr = aws_input_stream_new_from_open_file(allocator, Libc.FILE(body))
            elseif body isa Form
                # we set the request.body to the Form bytes in order to gc-preserve them
                is.bodyref = read(body)
                is.bodycursor = aws_byte_cursor(sizeof(is.bodyref), pointer(is.bodyref))
                is.ptr = aws_input_stream_new_from_cursor(allocator, FieldRef(is, :bodycursor))
            elseif body isa IO
                # we set the request.body to the IO bytes in order to gc-preserve them
                bytes = readavailable(body)
                while !eof(body)
                    append!(bytes, readavailable(body))
                end
                is.bodyref = bytes
                is.bodycursor = aws_byte_cursor(sizeof(is.bodyref), pointer(is.bodyref))
                is.ptr = aws_input_stream_new_from_cursor(allocator, FieldRef(is, :bodycursor))
            else
                throw(ArgumentError("request body must be a string, vector of UInt8, NamedTuple, AbstractDict, HTTP.Form, or IO"))
            end
            aws_input_stream_get_length(is.ptr, FieldRef(is, :bodylen)) != 0 && aws_throw_error()
            if !(is.bodylen > 0)
                aws_input_stream_release(is.ptr)
                is.ptr = C_NULL
            end
        else
            # assume a chunked request body; any kind of iterable where elements are RequestBodyTypes
            @assert Base.isiterable(typeof(body)) "chunked request body must be an iterable"
            is.bodyref = body
        end
    end
    return finalizer(x -> aws_input_stream_release(x.ptr), is)
end

function setinputstream!(msg::Message, body)
    aws_http_message_set_body_stream(msg.ptr, C_NULL)
    msg.inputstream = nothing
    body === nothing && return
    input_stream = InputStream(msg.allocator, body)
    setfield!(msg, :inputstream, input_stream)
    if input_stream.ptr != C_NULL
        aws_http_message_set_body_stream(msg.ptr, input_stream.ptr)
        if body isa Union{AbstractDict, NamedTuple}
            setheaderifabsent(msg.headers, "content-type", "application/x-www-form-urlencoded")
        elseif body isa Form
            setheaderifabsent(msg.headers, "content-type", content_type(body))
        end
        setheader(msg.headers, "content-length", string(input_stream.bodylen))
    end
    return
end

mutable struct Request <: Message
    allocator::Ptr{aws_allocator}
    ptr::Ptr{aws_http_message}
    inputstream::Union{Nothing, InputStream} # used for outgoing request body
    # only set in server-side request handlers
    body::Union{Nothing, Vector{UInt8}}
    route::Union{Nothing, String}
    params::Union{Nothing, Dict{String, String}}
    cookies::Any # actually Union{Nothing, Vector{Cookie}}

    function Request(method, path, headers=nothing, body=nothing, http2::Bool=false, allocator=default_aws_allocator())
        ptr = http2 ?
          aws_http2_message_new_request(allocator) :
          aws_http_message_new_request(allocator)
        ptr == C_NULL && aws_throw_error()
        try
            GC.@preserve method aws_http_message_set_request_method(ptr, aws_byte_cursor_from_c_str(method)) != 0 && aws_throw_error()
            GC.@preserve path aws_http_message_set_request_path(ptr, aws_byte_cursor_from_c_str(path)) != 0 && aws_throw_error()
            request_headers = Headers(aws_http_message_get_headers(ptr))
            if headers !== nothing
                for (k, v) in headers
                    addheader(request_headers, k, v)
                end
            end
            req = new(allocator, ptr)
            req.body = nothing
            req.inputstream = nothing
            req.route = nothing
            req.params = nothing
            req.cookies = nothing
            body !== nothing && setinputstream!(req, body)
            return finalizer(_ -> aws_http_message_release(ptr), req)
        catch
            aws_http_message_release(ptr)
            rethrow()
        end
    end
end

ptr(x) = getfield(x, :ptr)

function Base.getproperty(x::Request, s::Symbol)
    if s == :method
        out = Ref{aws_byte_cursor}()
        GC.@preserve out begin
            aws_http_message_get_request_method(ptr(x), out) != 0 && return nothing
            return str(out[])
        end
    elseif s == :path || s == :target || s == :uri
        out = Ref{aws_byte_cursor}()
        GC.@preserve out begin
            aws_http_message_get_request_path(ptr(x), out) != 0 && return nothing
            path = str(out[])
            return s == :uri ? URI(path) : path
        end
    elseif s == :headers
        return Headers(aws_http_message_get_headers(ptr(x)))
    elseif s == :version
        return aws_http_message_get_protocol_version(ptr(x)) == AWS_HTTP_VERSION_2 ? "2" : "1.1"
    else
        return getfield(x, s)
    end
end

function Base.setproperty!(x::Request, s::Symbol, v)
    if s == :method
        GC.@preserve v aws_http_message_set_request_method(x.ptr, aws_byte_cursor_from_c_str(v)) != 0 && aws_throw_error()
    elseif s == :path
        GC.@preserve v aws_http_message_set_request_path(x.ptr, aws_byte_cursor_from_c_str(v)) != 0 && aws_throw_error()
    elseif s == :headers
        addheaders(x.headers, v)
    else
        setfield!(x, s, v)
    end
end

function print_header(io, h)
    key = h.name
    val = h.value
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
    write(io, string(method, " ", path, " HTTP/$version\r\n"))
    for h in headers
        print_header(io, h)
    end
    write(io, "\r\n")
    body !== nothing ? write(io, body) : write(io, "[request body streamed]")
    write(io, "\n\"\"\"\n")
    return
end

getbody(r::Message) = isdefined(r, :inputstream) ? r.inputstream.bodyref : r.body

print_request(io::IO, r::Request) = print_request(io, r.method, r.version, r.path, r.headers, getbody(r))

function Base.show(io::IO, r::Request)
    println(io, "HTTP.Request:")
    print_request(io, r)
end

method(r::Request) = r.method
target(r::Request) = r.path
headers(r::Request) = r.headers
body(r::Request) = r.body

resource(uri::URI) = string(isempty(uri.path)      ? "/" :     uri.path,
                            !isempty(uri.query)    ? "?" : "", uri.query,
                            !isempty(uri.fragment) ? "#" : "", uri.fragment)

mutable struct RequestMetrics
    request_body_length::Int
    response_body_length::Int
    nretries::Int
    stream_metrics::Union{Nothing, aws_http_stream_metrics}
end

RequestMetrics() = RequestMetrics(0, 0, 0, nothing)

mutable struct Response <: Message
    allocator::Ptr{aws_allocator}
    ptr::Ptr{aws_http_message}
    inputstream::Union{Nothing, InputStream}
    body::Union{Nothing, Vector{UInt8}} # only set for client-side response body when no user-provided response_body
    metrics::RequestMetrics
    request::Request

    function Response(status::Integer, headers, body, http2::Bool=false, allocator=default_aws_allocator())
        ptr = http2 ?
            aws_http2_message_new_response(allocator) :
            aws_http_message_new_response(allocator)
        ptr == C_NULL && aws_throw_error()
        try
            GC.@preserve status aws_http_message_set_response_status(ptr, status) != 0 && aws_throw_error()
            response_headers = Headers(aws_http_message_get_headers(ptr))
            if headers !== nothing
                for (k, v) in headers
                    addheader(response_headers, k, v)
                end
            end
            resp = new(allocator, ptr)
            resp.body = nothing
            resp.inputstream = nothing
            body !== nothing && setinputstream!(resp, body)
            return finalizer(_ -> aws_http_message_release(ptr), resp)
        catch
            aws_http_message_release(ptr)
            rethrow()
        end
    end
    Response() = new(C_NULL, C_NULL, nothing, nothing)
end

Response(status::Integer, body) = Response(status, nothing, Vector{UInt8}(string(body)))
Response(status::Integer) = Response(status, nothing, nothing)

getresponse(r::Response) = r

bodylen(m::Message) = isdefined(m, :inputstream) && m.inputstream !== nothing ? m.inputstream.bodylen : 0

function Base.getproperty(x::Response, s::Symbol)
    if s == :status
        ref = Ref{Cint}()
        aws_http_message_get_response_status(x.ptr, ref) != 0 && return nothing
        return Int(ref[])
    elseif s == :headers
        return Headers(aws_http_message_get_headers(x.ptr))
    elseif s == :version
        return aws_http_message_get_protocol_version(x.ptr) == AWS_HTTP_VERSION_2 ? "2" : "1.1"
    else
        return getfield(x, s)
    end
end

function Base.setproperty!(x::Response, s::Symbol, v)
    if s == :status
        GC.@preserve v aws_http_message_set_response_status(x.ptr, v) != 0 && aws_throw_error()
    elseif s == :headers
        addheaders(x.headers, v)
    else
        setfield!(x, s, v)
    end
end

function print_response(io, status, version, headers, body)
    write(io, "\"\"\"\n")
    write(io, string("HTTP/$version ", status, "\r\n"))
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