abstract Scheme

immutable http <: Scheme end
immutable https <: Scheme end
# immutable ws <: Scheme end
# immutable wss <: Scheme end

sockettype(::Type{http}) = TCPSocket
sockettype(::Type{https}) = TLS.SSLContext
schemetype(::Type{TCPSocket}) = http
schemetype(::Type{TLS.SSLContext}) = https

typealias Headers Dict{String,String}

?{T}(::Type{T}) = Union{T, Void}
const null = nothing
isnull(v::Void) = true
isnull(x) = false
function get{T, R}(value::T, name::Symbol, default::R)::R
    val = getfield(value, name)::?(R)
    return isnull(val) ? default : val
end

"""
    RequestOptions(; chunksize=, connecttimeout=, readtimeout=, tlsconfig=, maxredirects=, allowredirects=)

A type to represent various http request options. Lives as a separate type so that options can be set
at the `HTTP.Client` level to be applied to every request sent. Options include:

  * `chunksize::Int`: if a request body is larger than `chunksize`, the "chunked-transfer" http mechanism will be used and chunks will be sent no larger than `chunksize`
  * `connecttimeout::Float64`: sets a timeout on how long to wait when trying to connect to a remote host; default = 10.0 seconds
  * `readtimeout::Float64`: sets a timeout on how long to wait when receiving a response from a remote host; default = 9.0 seconds
  * `tlsconfig::TLS.SSLConfig`: a valid `TLS.SSLConfig` which will be used to initialize every https connection
  * `maxredirects::Int`: the maximum number of redirects that will automatically be followed for an http request
  * `allowredirects::Bool`: whether redirects should be allowed to be followed at all; default = `true`
"""
type RequestOptions
    chunksize::?(Int)
    gzip::?(Bool)
    connecttimeout::?(Float64)
    readtimeout::?(Float64)
    tlsconfig::?(TLS.SSLConfig)
    maxredirects::?(Int)
    allowredirects::?(Bool)
    RequestOptions(ch::?(Int), gzip::?(Bool), ct::?(Float64), rt::?(Float64), tls::?(TLS.SSLConfig), mr::?(Int), ar::?(Bool)) =
        new(ch, gzip, ct, rt, tls, mr, ar)
end

const RequestOptionsFieldTypes = Dict(:chunksize=>Int, :gzip=>Bool,
                                      :connecttimeout=>Float64, :readtimeout=>Float64,
                                      :tlsconfig=>TLS.SSLConfig,
                                      :maxredirects=>Int, :allowredirects=>Bool)

function RequestOptions(options::RequestOptions; kwargs...)
    for (k, v) in kwargs
        setfield!(options, k, convert(RequestOptionsFieldTypes[k], v))
    end
    return options
end

RequestOptions(chunk=null, gzip=null, ct=null, rt=null, tls=null, mr=null, ar=null; kwargs...) =
    RequestOptions(RequestOptions(chunk, gzip, ct, rt, tls, mr, ar); kwargs...)

function update!(opts1::RequestOptions, opts2::RequestOptions)
    for i = 1:nfields(RequestOptions)
        f = fieldname(RequestOptions, i)
        isnull(getfield(opts1, f)) && setfield!(opts1, f, getfield(opts2, f))
    end
    return opts1
end

"""
    Request()
    Request(method, uri, headers, body; options=RequestOptions())

A type representing an http request. `method` can be provided as a string or `HTTP.GET` type enum.
`uri` can be provided as an actual `HTTP.URI` or string. `headers` should be provided as a `Dict`.
`body` may be provided as string, byte vector, IO, or `HTTP.FIFOBuffer`.
`options` should be a `RequestOptions` type, see `?HTTP.RequestOptions` for details.

Accessor methods include:
  * `HTTP.method`: method for a request
  * `HTTP.major`: major http version for a request
  * `HTTP.minor`: minor http version for a request
  * `HTTP.uri`: uri for a request
  * `HTTP.headers`: headers for a request
  * `HTTP.body`: body for a request as a `HTTP.FIFOBuffer`
"""
type Request
    method::HTTP.Method
    major::Int16
    minor::Int16
    uri::URI
    headers::Headers # includes cookies
    body::FIFOBuffer
end

# accessors
method(r::Request) = r.method
major(r::Request) = r.major
minor(r::Request) = r.minor
uri(r::Request) = r.uri
headers(r::Request) = r.headers
body(r::Request) = r.body

defaultheaders(::Type{Request}) = Headers(
    "User-Agent" => "HTTP.jl/0.0.0",
    "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8,application/json"
)

function Request(m::HTTP.Method, uri::URI, userheaders::Headers, body::FIFOBuffer;
                    options::RequestOptions=RequestOptions(),
                    verbose::Bool=false,
                    io::IO=STDOUT)
    if m != CONNECT
        headers = defaultheaders(Request)
        headers["Host"] = host(uri)
    else
        headers = Headers()
    end
    if !isempty(userinfo(uri)) && !haskey(headers,"Authorization")
        headers["Authorization"] = "Basic $(base64encode(userinfo(uri)))"
        @log(verbose, io, "adding basic authentication header")
    end
    if shouldchunk(body, get(options, :chunksize, typemax(Int)))
        # chunked-transfer
        @log(verbose, io, "using chunked transfer encoding")
        headers["Transfer-Encoding"] = "chunked" * (get(options, :gzip, false) ? "; gzip" : "")
    else
        # just set the Content-Length
        if !(m in (GET, HEAD, CONNECT))
            @log(verbose, io, "setting Content-Length header")
            headers["Content-Length"] = dec(length(body))
        end
    end
    if !haskey(headers, "Content-Type") && length(body) > 0
        sn = HTTP.sniff(body)
        headers["Content-Type"] = sn
        @log(verbose, io, "setting Content-Type header to: $sn")
    end
    return Request(m, Int16(1), Int16(1), uri, merge!(headers, userheaders), body)
end

Request{T}(method, uri, h, body::T; options::RequestOptions=RequestOptions(), io::IO=STDOUT, verbose::Bool=false) = Request(convert(HTTP.Method, method),
                               isa(uri, String) ? URI(uri; isconnect=(method == "CONNECT" || method == CONNECT)) : uri,
                               h, FIFOBuffer(body); options=options, io=io, verbose=verbose)

Request() = Request(GET, Int16(1), Int16(1), URI(""), Headers(), FIFOBuffer())

==(a::Request,b::Request) = (a.method    == b.method)    &&
                            (a.major     == b.major)     &&
                            (a.minor     == b.minor)     &&
                            (a.uri       == b.uri)       &&
                            (a.headers   == b.headers)   &&
                            (a.body      == b.body)

Base.showcompact(io::IO, r::Request) = print(io, "Request(\"", resource(r.uri), "\", ",
                                        length(r.headers), " headers, ",
                                        length(r.body), " bytes in body)")

"""
    Response(status)
    Response(status, headers, body)

A type representing an http response. `status` represents the http status code for the response.
`headers` should be provided as a `Dict`. `body` can be provided as a string, byte vector, IO, or `HTTP.FIFOBuffer`.

Accessor methods include:
  * `HTTP.status`: status for a response
  * `HTTP.statustext`: statustext for a response
  * `HTTP.major`: major http version for a response
  * `HTTP.minor`: minor http version for a response
  * `HTTP.cookies`: cookies for a response, returned as a `Vector{HTTP.Cookie}`
  * `HTTP.headers`: headers for a response
  * `HTTP.request`: the `HTTP.Request` that resulted in this response
  * `HTTP.history`: history for a response if redirects were followed from an original request
  * `HTTP.body`: body for a response as a `HTTP.FIFOBuffer`

Two convenience methods are provided for accessing a response body:
  * `string(r)`: consume the reponse body, returning it as a `String`
  * `HTTP.bytes(r)`: consume the response body, returning it as a `Vector{UInt8}`
"""
type Response
    status::Int32
    major::Int16
    minor::Int16
    cookies::Vector{Cookie}
    headers::Headers
    body::FIFOBuffer
    request::Nullable{Request}
    history::Vector{Response}
end

# accessors
status(r::Response) = r.status
major(r::Response) = r.major
minor(r::Response) = r.minor
cookies(r::Response) = r.cookies
headers(r::Response) = r.headers
body(r::Response) = r.body
request(r::Response) = r.request
history(r::Response) = r.history
statustext(r::Response) = Base.get(STATUS_CODES, r.status, "Unknown Code")
body(r::Union{Request, Response}) = r.body
bytes(r::Response) = readavailable(r.body)
Base.string(r::Response) = String(bytes(r))

Response(; status::Int=200,
         cookies::Vector{Cookie}=Cookie[],
         headers::Headers=Headers(),
         body::FIFOBuffer=FIFOBuffer(),
         request::Nullable{Request}=Nullable{Request}(),
         history::Vector{Response}=Response[]) =
    Response(status, Int16(1), Int16(1), cookies, headers, body, request, history)

Response(n::Integer, r::Request) = Response(; body=FIFOBuffer(n), request=Nullable(r))
Response(s::Integer) = Response(; status=s)
Response(b::Union{Vector{UInt8}, String}) = Response(; headers=defaultheaders(Response), body=FIFOBuffer(b))
Response(s::Integer, h::Headers, body) = Response(; status=s, headers=h, body=FIFOBuffer(body))

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

const CRLF = "\r\n"

## Request & Response writing
# start lines
function startline(io::IO, r::Request)
    res = resource(uri(r); isconnect=r.method == CONNECT)
    res = res == "" ? "/" : res
    write(io, "$(r.method) $res HTTP/$(r.major).$(r.minor)$CRLF")
end

function startline(io::IO, r::Response)
    write(io, "HTTP/$(r.major).$(r.minor) $(r.status) $(statustext(r))$CRLF")
end

# headers
function headers(io::IO, r::Request)
    for (k, v) in headers(r)
        write(io, "$k: $v$CRLF")
    end
    write(io, CRLF)
end

function headers(io::IO, r::Response)
    length(r.body) > 0 && setindex!(r.headers, string(length(r.body)), "Content-Length")
    for (k, v) in headers(r)
        write(io, "$k: $v$CRLF")
    end
    write(io, CRLF)
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

function body(io::IO, r::Request, opts)
    hasmessagebody(r) || return
    sz = length(r.body)
    chksz = get(opts, :chunksize, typemax(Int))
    if shouldchunk(r.body, chksz)
        while !eof(r.body)
            bytes = read(r.body, chksz) # read at most chunksize
            chunk = length(bytes)
            chunk == 0 && continue
            ch = "$(hex(chunk))$CRLF"
            write(io, ch)
            write(io, bytes)
            write(io, CRLF)
        end
        write(io, "$(hex(0))$CRLF$CRLF")
    else
        write(io, r.body)
    end
    return
end

function body(io::IO, r::Response, opts)
    hasmessagebody(r) || return
    write(io, r.body)
    return
end

function Base.write(io::IO, r::Union{Request, Response}, opts)
    startline(io, r)
    headers(io, r)
    body(io, r, opts)
    return
end

function Base.show(io::IO, r::Union{Request,Response})
    println(io, typeof(r), ":")
    println(io, "\"\"\"")
    startline(io, r)
    headers(io, r)
    if iscompressed(String(r.body))
        println(io, "[compressed $(typeof(r)) body of $(length(r.body)) bytes]")
    elseif length(r.body) > 1000
        println(io, "[$(typeof(r)) body of $(length(r.body)) bytes]")
        println(io, String(r.body)[1:1000])
        println(io, "...")
    elseif length(r.body) > 0
        println(io, String(r.body))
    end
    print(io, "\"\"\"")
end
