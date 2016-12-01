typealias Headers Dict{String,String}
headers() = Headers(
    "Server"            => "Julia/$VERSION",
    "Content-Type"      => "text/html; charset=utf-8",
    "Content-Language"  => "en",
    "Date"              => Dates.format(now(Dates.UTC), Dates.RFC1123Format) )

type Request
    method::String      # HTTP method string (e.g. "GET")
    major::Int8
    minor::Int8
    resource::String    # Resource requested (e.g. "/hello/world")
    uri::URI
    headers::Headers
    keepalive::Bool
    data::Vector{UInt8}
end
Request() = Request("", 1, 1, "", URI(""), Headers(), true, UInt8[])
Request(method, resource, headers, data) = Request(method, 1, 1, resource, URI(resource), headers, true, data)

==(a::Request,b::Request) = (a.method    == b.method)    &&
                            (a.major     == b.major)     &&
                            (a.minor     == b.minor)     &&
                            (a.resource  == b.resource)  &&
                            (a.uri       == b.uri)       &&
                            (a.headers   == b.headers)   &&
                            (a.keepalive == b.keepalive) &&
                            (a.data      == b.data)

function Base.show(io::IO, r::Request)
    println(io, "$(r.method) $(r.resource) HTTP/1.1")
    for (k, v) in r.headers
        println(io, "$k: $v")
    end
    if length(r.data) > 100
        println(io, "[Request body of $(length(r.data)) bytes]")
    elseif length(r.data) > 0
        println(io, String(r.data))
    end
end
Base.showcompact(io::IO, r::Request) = print(io, "Request(", r.resource, ", ",
                                        length(r.headers), " headers, ",
                                        sizeof(r.data), " bytes in body)")

type Cookie
    name::String
    value::String
    attrs::Dict{String, String}
end
Cookie(name, value) = Cookie(name, value, Dict{String, String}())
Base.show(io::IO, c::Cookie) = print(io, "Cookie(", c.name, ", ", c.value,
                                        ", ", length(c.attrs), " attributes)")

type Response
    status::Int
    major::Int8
    minor::Int8
    headers::Headers
    cookies::Dict{String, Cookie}
    data::Vector{UInt8}
    request::Nullable{Request}
    history::Vector{Response}
end

typealias HttpData Union{Vector{UInt8}, AbstractString}
Response(s::Int, h::Headers, d::HttpData) =
  Response(s, 1, 1, h, Dict{String, Cookie}(), d, Nullable(), Response[])
Response(status, major, minor, headers, cookies, data) =
    Response(status, major, minor, headers, cookies, data, Nullable(), Response[])

Response(s::Int, h::Headers)              = Response(s, h, UInt8[])
Response(s::Int, d::HttpData)             = Response(s, headers(), d)
Response(d::HttpData, h::Headers)         = Response(200, h, d)
Response(d::HttpData)                     = Response(d, headers())
Response(s::Int)                          = Response(s, headers(), UInt8[])
Response()                                = Response(200)

==(a::Response,b::Response) = (a.status  == b.status)  &&
                              (a.major   == b.major)   &&
                              (a.minor   == b.minor)   &&
                              (a.headers == b.headers) &&
                              (a.cookies == b.cookies) &&
                              (a.data    == b.data)

function Base.show(io::IO, r::Response)
    println(io, "HTTP/1.1 $(r.status) ", get(STATUS_CODES, r.status, "Unknown Code"))
    for (k, v) in r.headers
        println(io, "$k: $v")
    end
    if length(r.data) > 100
        println(io, "[Response body of $(length(r.data)) bytes]")
    elseif length(r.data) > 0
        println(io, String(r.data))
    end
end

function Base.showcompact(io::IO, r::Response)
    print(io, "Response(", r.status, " ", get(STATUS_CODES, r.status, "Unknown Code"), ", ",
          length(r.headers)," headers, ",
          sizeof(r.data)," bytes in body)")
end

"Converts a `Response` to an HTTP response string"
function Base.write(io::IO, response::Response)
    write(io, join(["HTTP/1.1", response.status, STATUS_CODES[response.status], "\r\n"], " "))

    response.headers["Content-Length"] = string(sizeof(response.data))
    for (header,value) in response.headers
        write(io, string(join([ header, ": ", value ]), "\r\n"))
    end
    for (cookie_name, cookie) in response.cookies
        write(io, "Set-Cookie: ", cookie_name, "=", cookie.value)
        for (attr_name, attr_val) in cookie.attrs
            write(io, "; ", attr_name)
            if !isempty(attr_val)
                write(io, "=", attr_val)
            end
        end
        write(io, "\r\n")
    end

    write(io, "\r\n")
    write(io, response.data)
end
