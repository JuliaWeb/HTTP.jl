abstract type Scheme end

struct http <: Scheme end
struct https <: Scheme end
# struct ws <: Scheme end
# struct wss <: Scheme end

sockettype(::Type{http}) = TCPSocket
sockettype(::Type{https}) = TLS.SSLContext
schemetype(::Type{TCPSocket}) = http
schemetype(::Type{TLS.SSLContext}) = https

const Headers = Dict{String,String}

const Option{T} = Union{T, Void}
not(::Void) = true
not(x) = false
function get(value::T, name::Symbol, default::R)::R where {T, R}
    val = getfield(value, name)::Option{R}
    return not(val) ? default : val
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
  * `forwardheaders::Bool`: whether user-provided headers should be forwarded on redirects; default = `false`
  * `retries::Int`: # of times a request will be tried before throwing an error; default = 3
"""
mutable struct RequestOptions
    chunksize::Option{Int}
    gzip::Option{Bool}
    connecttimeout::Option{Float64}
    readtimeout::Option{Float64}
    tlsconfig::Option{TLS.SSLConfig}
    maxredirects::Option{Int}
    allowredirects::Option{Bool}
    forwardheaders::Option{Bool}
    retries::Option{Int}
    RequestOptions(ch::Option{Int}, gzip::Option{Bool}, ct::Option{Float64}, rt::Option{Float64}, tls::Option{TLS.SSLConfig}, mr::Option{Int}, ar::Option{Bool}, fh::Option{Bool}, tr::Option{Int}) =
        new(ch, gzip, ct, rt, tls, mr, ar, fh, tr)
end

const RequestOptionsFieldTypes = Dict(:chunksize=>Int, :gzip=>Bool,
                                      :connecttimeout=>Float64, :readtimeout=>Float64,
                                      :tlsconfig=>TLS.SSLConfig,
                                      :maxredirects=>Int, :allowredirects=>Bool,
                                      :forwardheaders=>Bool,
                                      :retries=>Int)

function RequestOptions(options::RequestOptions; kwargs...)
    for (k, v) in kwargs
        setfield!(options, k, convert(RequestOptionsFieldTypes[k], v))
    end
    return options
end

RequestOptions(chunk=nothing, gzip=nothing, ct=nothing, rt=nothing, tls=nothing, mr=nothing, ar=nothing, fh=nothing, tr=nothing; kwargs...) =
    RequestOptions(RequestOptions(chunk, gzip, ct, rt, tls, mr, ar, fh, tr); kwargs...)

function update!(opts1::RequestOptions, opts2::RequestOptions)
    for i = 1:nfields(RequestOptions)
        f = fieldname(RequestOptions, i)
        not(getfield(opts1, f)) && setfield!(opts1, f, getfield(opts2, f))
    end
    return opts1
end

# Request
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

Two convenience methods are provided for accessing a request body:
  * `take!(r)`: consume the request body, returning it as a `Vector{UInt8}`
  * `String(take!(r))`: consume the request body, returning it as a `String`
"""
mutable struct Request
    method::HTTP.Method
    major::Int16
    minor::Int16
    uri::URI
    headers::Headers # includes cookies
    body::Union{FIFOBuffer, Form}
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

function Request(m::HTTP.Method, uri::URI, userheaders::Headers, b;
                    options::RequestOptions=RequestOptions(),
                    verbose::Bool=false,
                    io::Option{IO}=STDOUT)
    if m != CONNECT
        headers = defaultheaders(Request)
        headers["Host"] = string(hostname(uri), hasport(uri) ? string(':', port(uri)) : "")
        if m != GET
            headers["Origin"] = headers["Host"]
        end
    else
        headers = Headers()
    end
    if !isempty(userinfo(uri)) && !haskey(headers, "Authorization")
        headers["Authorization"] = "Basic $(base64encode(userinfo(uri)))"
        @log(verbose, io, "adding basic authentication header")
    end
    if isa(b, Dict) || isa(b, Form)
        # form data
        body = Form(b)
        headers["Content-Type"] = "multipart/form-data; boundary=$(body.boundary)"
    else
        body = FIFOBuffer(b)
    end
    if !haskey(headers, "Content-Type") && length(body) > 0 && !isa(body, Form)
        sn = HTTP.sniff(body)
        headers["Content-Type"] = sn
        @log(verbose, io, "setting Content-Type header to: $sn")
    end
    return Request(m, Int16(1), Int16(1), uri, merge!(headers, userheaders), body)
end

Request(method, uri, h, body::T; options::RequestOptions=RequestOptions(), io::IO=STDOUT, verbose::Bool=false) where {T} =
    Request(convert(HTTP.Method, method), isa(uri, String) ? URI(uri; isconnect=(method == "CONNECT" || method == CONNECT)) : uri,
            h, body; options=options, io=io, verbose=verbose)

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
  * `take!(r)`: consume the response body, returning it as a `Vector{UInt8}`
  * `String(take!(r))`: consume the response body, returning it as a `String`
"""
mutable struct Response
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
request(r::Response) = r.request
history(r::Response) = r.history
statustext(r::Response) = Base.get(STATUS_CODES, r.status, "Unknown Code")
body(r::Union{Request, Response}) = r.body
Base.take!(r::Union{Request, Response}) = readavailable(body(r))
Base.String(r::Union{Request, Response}) = String(body(r))

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

## Request & Response writing
# start lines
function startline(io::IO, r::Request)
    res = resource(uri(r); isconnect=r.method == CONNECT)
    res = ifelse(res == "", "/", res)
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
    # write(io, CRLF); we let the body write this in case of chunked transfer
end

function headers(io::IO, r::Response)
    hasmessagebody(r) && setindex!(r.headers, string(length(body(r))), "Content-Length")
    for (k, v) in headers(r)
        write(io, "$k: $v$CRLF")
    end
    # write(io, CRLF); we let the body write this in case of chunked transfer
end

# body
function body(io::IO, r::Request, opts, consume)
    (length(r.body) == 0 || r.method in (GET, HEAD, CONNECT)) && (write(io, "$CRLF"); return)
    # make sure we don't try to "show" the body if we're doing an asynchronous upload
    isa(r.body, FIFOBuffer) && r.body.task != current_task() && !consume && return
    chksz = get(opts, :chunksize, typemax(Int))
    if isa(r.body, Form)
        index = r.body.index
        foreach(mark, r.body.data)
    else
        f, l, nb = r.body.f, r.body.l, r.body.nb
    end
    if length(r.body) > chksz || (isa(r.body, FIFOBuffer) && r.body.task != current_task())
        # chunked transfer
        write(io, "Transfer-Encoding: chunked$CRLF$CRLF")
        while !eof(r.body)
            bytes = read(r.body, chksz) # read at most chunksize
            chunk = length(bytes)
            chunk == 0 && continue
            write(io, "$(hex(chunk))$CRLF")
            write(io, bytes, CRLF)
        end
        write(io, "$(hex(0))$CRLF$CRLF")
    else
        write(io, "Content-Length: $(dec(length(r.body)))$CRLF$CRLF")
        write(io, r.body)
    end
    if isa(r.body, Form)
        r.body.index = index
        foreach(reset, r.body.data)
    else
        r.body.f = f
        r.body.l = l
        r.body.nb = nb
    end
    return
end

# https://tools.ietf.org/html/rfc7230#section-3.3
function hasmessagebody(r::Response)
    if 100 <= status(r) < 200 || status(r) == 204 || status(r) == 304
        return false
    elseif !Base.isnull(request(r))
        req = Base.get(request(r))
        method(req) in (HEAD, CONNECT) && return false
    end
    return true
end

function body(io::IO, r::Response, opts, consume)
    write(io, "$CRLF")
    hasmessagebody(r) || return
    write(io, String(r.body))
    return
end

function Base.write(io::IO, r::Union{Request, Response}, opts, consume=true)
    i = IOBuffer()
    startline(i, r)
    headers(i, r)
    body(i, r, opts, consume)
    write(io, take!(i))
    return
end

function Base.show(io::IO, r::Union{Request,Response}, opts=RequestOptions())
    println(io, typeof(r), ":")
    println(io, "\"\"\"")
    startline(io, r)
    headers(io, r)
    buf = IOBuffer()
    body(buf, r, opts, false)
    b = take!(buf)
    if length(b) > 2
        contenttype = HTTP.sniff(b)
        if contenttype in DISPLAYABLE_TYPES
            if length(b) > 750
                println(io, "\n[$(typeof(r)) body of $(length(b)) bytes]")
                println(io, String(b)[1:750])
                println(io, "⋮")
            else
                println(io, String(b))
            end
        else
            contenttype = Base.get(r.headers, "Content-Type", contenttype)
            encoding = Base.get(r.headers, "Content-Encoding", "")
            encodingtxt = encoding == "" ? "" : " with '$encoding' encoding"
            println(io, "\n[$(length(b)) bytes of '$contenttype' data$encodingtxt]")
        end
    else
        print(io, String(b))
    end
    print(io, "\"\"\"")
end
