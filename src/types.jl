abstract Scheme

immutable http <: Scheme end
immutable https <: Scheme end
# immutable ws <: Scheme end
# immutable wss <: Scheme end

typealias Headers Dict{String,String}

?(x) = Union{x,Void}
const null = nothing
isnull(v::Void) = true
isnull(x) = false
function get(value, name::Symbol, default)
    val = getfield(value, name)
    return isnull(val) ? default : val
end

type RequestOptions
    chunksize::?(Int)
    gzip::?(Bool)
    connecttimeout::?(Float64)
    readtimeout::?(Float64)
    tlsconfig::?(TLS.SSLConfig)
    maxredirects::?(Int)
    RequestOptions(ch::?(Int), gzip::?(Bool), ct::?(Float64), rt::?(Float64), tls::?(TLS.SSLConfig), mr::?(Int)) =
        new(ch, gzip, ct, rt, tls, mr)
end

function RequestOptions(options::RequestOptions; kwargs...)
    for (k, v) in kwargs
        setfield!(options, k, v)
    end
    return options
end

function update!(opts1::RequestOptions, opts2::RequestOptions)
    for i = 1:nfields(RequestOptions)
        f = fieldname(RequestOptions, i)
        isnull(getfield(opts1, f)) && setfield!(opts1, f, getfield(opts2, f))
    end
    return opts1
end

RequestOptions(chunk=null, gzip=null, ct=null, rt=null, tls=null, mr=null; kwargs...) =
    RequestOptions(RequestOptions(chunk, gzip, ct, rt, tls, mr); kwargs...)

type Request
    method::String # HTTP method string (e.g. "GET")
    major::Int8
    minor::Int8
    uri::URI
    headers::Headers
    keepalive::Bool
    body::FIFOBuffer # Vector{UInt8}, String, IO, FIFOBuffer
    options::RequestOptions
end

Request(; args...) = Request("GET", Int8(1), Int8(1), URI(""), Headers(), true, FIFOBuffer(), RequestOptions(; args...))

defaultheaders(::Type{Request}) = Headers(
    "User-Agent" => "HTTP.jl/0.0.0",
    "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
)

Request(method, uri, userheaders=Headers(), body=FIFOBuffer(); args...) = Request(method, uri, userheaders, body, RequestOptions(; args...))

function Request{T}(method, uri, userheaders, body::T, options::RequestOptions)
    headers = defaultheaders(Request)

    headers["Host"] = uri.port == 0 ? uri.host : "$(uri.host):$(uri.port)"

    if !isempty(uri.userinfo) && !haskey(headers,"Authorization")
        headers["Authorization"] = "Basic $(base64encode(uri.userinfo))"
    end
    fifobody = FIFOBuffer(body)
    if shouldchunk(fifobody, get(options, :chunksize, typemax(Int)))
        # chunked-transfer
        headers["Transfer-Encoding"] = "chunked" * (get(options, :gzip, false) ? "; gzip" : "")
    else
        # just set the Content-Length
        if !(method in ("GET", "HEAD", "CONNECT"))
            headers["Content-Length"] = dec(length(fifobody))
        end
    end
    if !haskey(headers, "Content-Type") && length(fifobody) > 0
        headers["Content-Type"] = HTTP.sniff(fifobody)
    end
    return Request(method, Int8(1), Int8(1), uri, merge!(headers, userheaders), true, fifobody, options)
end

==(a::Request,b::Request) = (a.method    == b.method)    &&
                            (a.major     == b.major)     &&
                            (a.minor     == b.minor)     &&
                            (a.uri       == b.uri)       &&
                            (a.headers   == b.headers)   &&
                            (a.keepalive == b.keepalive) &&
                            (a.body      == b.body)

Base.showcompact(io::IO, r::Request) = print(io, "Request(", resource(r.uri), ", ",
                                        length(r.headers), " headers, ",
                                        length(r.body), " bytes in body)")

type Response
    status::Int
    major::Int8
    minor::Int8
    headers::Headers
    keepalive::Bool
    cookies::Vector{Cookie}
    body::FIFOBuffer
    bodytask::Task
    request::Nullable{Request}
    history::Vector{Response}
end

Response() = Response(200, 1, 1, Headers(), true, Cookie[], FIFOBuffer(), Task(1), Nullable(), Response[])
Response(n, r::Request) = Response(200, 1, 1, Headers(), true, Cookie[], FIFOBuffer(n), Task(1), Nullable(r), Response[])
Response(s::Int) = Response(s, defaultheaders(Response), FIFOBuffer())
Response(body::String) = Response(200, defaultheaders(Response), FIFOBuffer(body))
Response(s::Int, h::Headers, body) =
  Response(s, 1, 1, h, true, Cookie[], body, Task(1), Nullable(), Response[])

defaultheaders(::Type{Response}) = Headers(
    "Server"            => "Julia/$VERSION",
    "Content-Type"      => "text/html; charset=utf-8",
    "Content-Language"  => "en",
    "Date"              => Dates.format(now(Dates.UTC), Dates.RFC1123Format)
)

==(a::Response,b::Response) = (a.status  == b.status)  &&
                              (a.major   == b.major)   &&
                              (a.minor   == b.minor)   &&
                              (a.headers == b.headers) &&
                              (a.cookies == b.cookies) &&
                              (a.body    == b.body)

function Base.showcompact(io::IO, r::Response)
    print(io, "Response(", r.status, " ", Base.get(STATUS_CODES, r.status, "Unknown Code"), ", ",
          length(r.headers)," headers, ",
          length(r.body)," bytes in body)")
end

headers(r::Union{Request,Response}) = r.headers
history(r::Response) = r.history
cookies(r::Response) = r.cookies
status(r::Response) = r.status
statustext(r::Response) = Base.get(STATUS_CODES, r.status, "Unknown Code")

const CRLF = "\r\n"

## Request & Response writing
# start lines
function startline(io::IO, r::Request)
    write(io, "$(r.method) $(resource(r.uri)) HTTP/$(r.major).$(r.minor)$CRLF")
end

function startline(io::IO, r::Response)
    write(io, "HTTP/$(r.major).$(r.minor) $(r.status) $(statustext(r))$CRLF")
end

# headers
function headers(io::IO, r::Request)
    for (k, v) in headers(r)
        write(io, "$k: $v$CRLF")
    end
    cookies(io, r)
    write(io, CRLF)
end

function headers(io::IO, r::Response)
    r.headers["Content-Length"] = string(length(r.body))
    for (k, v) in headers(r)
        write(io, "$k: $v$CRLF")
    end
    cookies(io, r)
    write(io, CRLF)
end

# cookies
function cookies(io::IO, r::Request)

end

function cookies(io::IO, r::Response)

end

# body
hasmessagebody(r::Request) = length(r.body) > 0

# https://tools.ietf.org/html/rfc7230#section-3.3
function hasmessagebody(r::Response)
    if 100 <= r.status < 200 || r.status == 204 || r.status == 304
        return false
    elseif !Base.isnull(r.request)
        req = Base.get(r.request)
        if req.method in ("HEAD", "CONNECT")
            return false
        end
    end
    return true
end

shouldchunk(b::FIFOBuffer, chksz) = current_task() == b.task ? length(b) > chksz : true

function body(io::IO, r::Request)
    hasmessagebody(r) || return
    # if size of body is > chunksize or body is a FIFOBuffer, we chunk
    sz = length(r.body)
    if shouldchunk(r.body, get(r.options, :chunksize, typemax(Int)))
        while !eof(r.body)
            bytes = readbytes(r.body, r.options.chunksize) # read at most chunksize
            chunk = length(bytes)
            chunk == 0 && continue
            write(io, "$(hex(chunk))$CRLF")
            write(io, bytes)
            write(io, CRLF)
        end
        write(io, "$(hex(0))$CRLF$CRLF")
    else
        write(io, r.body)
    end
end

function body(io::IO, r::Response)
    hasmessagebody(r) || return
    write(io, r.body)
end

function Base.write(io::IO, r::Union{Request, Response})
    startline(io, r)
    headers(io, r)
    body(io, r)
    return
end

function Base.show(io::IO, r::Union{Request,Response})
    println(io, typeof(r), ":")
    println(io, "\"\"\"")
    startline(io, r)
    headers(io, r)
    if length(r.body) > 1000
        println(io, "[Request body of $(length(r.body)) bytes]")
    elseif length(r.body) > 0
        println(io, String(r.body))
    end
    println(io, "\"\"\"")
end
