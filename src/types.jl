abstract type Scheme end

struct http <: Scheme end
struct https <: Scheme end
# struct ws <: Scheme end
# struct wss <: Scheme end

sockettype(::Type{http}) = TCPSocket
sockettype(::Type{https}) = TLS.SSLContext
schemetype(::Type{TCPSocket}) = http
schemetype(::Type{TLS.SSLContext}) = https

const Headers = Dict{String, String}

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

  * `chunksize::Int`: if a request body is larger than `chunksize`, the "chunked-transfer" http mechanism will be used and chunks will be sent no larger than `chunksize`; default = `nothing`
  * `connecttimeout::Float64`: sets a timeout on how long to wait when trying to connect to a remote host; default = Inf. Note that while setting a timeout will affect the actual program control flow, there are current lower-level limitations that mean underlying resources may not actually be freed until their own timeouts occur (i.e. libuv sockets only timeout after 75 seconds, with no option to configure)
  * `readtimeout::Float64`: sets a timeout on how long to wait when receiving a response from a remote host; default = Int
  * `tlsconfig::TLS.SSLConfig`: a valid `TLS.SSLConfig` which will be used to initialize every https connection; default = `nothing`
  * `maxredirects::Int`: the maximum number of redirects that will automatically be followed for an http request; default = 5
  * `allowredirects::Bool`: whether redirects should be allowed to be followed at all; default = `true`
  * `forwardheaders::Bool`: whether user-provided headers should be forwarded on redirects; default = `false`
  * `retries::Int`: # of times a request will be tried before throwing an error; default = 3
  * `managecookies::Bool`: whether the request client should automatically store and add cookies from/to requests (following appropriate host-specific & expiration rules); default = `true`
  * `statusraise::Bool`: whether an `HTTP.StatusError` should be raised on a non-2XX response status code; default = `true`
  * `insecure::Bool`: whether an "https" connection should allow insecure connections (no TLS verification); default = `false`
  * `canonicalizeheaders::Bool`: whether header field names should be canonicalized in responses, e.g. `content-type` is canonicalized to `Content-Type`; default = `true`
  * `logbody::Bool`: whether the request body should be logged when `verbose=true` is passed; default = `true`
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
    managecookies::Option{Bool}
    statusraise::Option{Bool}
    insecure::Option{Bool}
    canonicalizeheaders::Option{Bool}
    logbody::Option{Bool}
    RequestOptions(ch::Option{Int}, gzip::Option{Bool}, ct::Option{Float64}, rt::Option{Float64}, tls::Option{TLS.SSLConfig}, mr::Option{Int}, ar::Option{Bool}, fh::Option{Bool}, tr::Option{Int}, mc::Option{Bool}, sr::Option{Bool}, i::Option{Bool}, h::Option{Bool}, lb::Option{Bool}) =
        new(ch, gzip, ct, rt, tls, mr, ar, fh, tr, mc, sr, i, h, lb)
end

const RequestOptionsFieldTypes = Dict(:chunksize      => Int,
                                      :gzip           => Bool,
                                      :connecttimeout => Float64,
                                      :readtimeout    => Float64,
                                      :tlsconfig      => TLS.SSLConfig,
                                      :maxredirects   => Int,
                                      :allowredirects => Bool,
                                      :forwardheaders => Bool,
                                      :retries        => Int,
                                      :managecookies  => Bool,
                                      :statusraise    => Bool,
                                      :insecure       => Bool,
                                      :canonicalizeheaders => Bool,
                                      :logbody => Bool)

function RequestOptions(options::RequestOptions; kwargs...)
    for (k, v) in kwargs
        setfield!(options, k, convert(RequestOptionsFieldTypes[k], v))
    end
    return options
end

RequestOptions(chunk=nothing, gzip=nothing, ct=nothing, rt=nothing, tls=nothing, mr=nothing, ar=nothing, fh=nothing, tr=nothing, mc=nothing, sr=nothing, i=nothing, h=nothing, lb=nothing; kwargs...) =
    RequestOptions(RequestOptions(chunk, gzip, ct, rt, tls, mr, ar, fh, tr, mc, sr, i, h, lb); kwargs...)

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
    Request(; method=HTTP.GET, uri=HTTP.URI(""), major=1, minor=1, headers=HTTP.Headers(), body="")

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
  * `String(r)`: consume the request body, returning it as a `String`
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
    "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8,application/json; charset=utf-8"
)
makeheaders(d::Dict) = Headers((string(k), string(v)) for (k, v) in d)

function Request(m::HTTP.Method, uri::URI, userheaders::Dict, b;
                    options::RequestOptions=RequestOptions(),
                    verbose::Bool=false,
                    logger::Option{IO}=STDOUT)
    if m != CONNECT
        headers = defaultheaders(Request)
        headers["Host"] = host(uri)
    else
        headers = Headers()
    end
    if !isempty(userinfo(uri)) && !haskey(headers, "Authorization")
        headers["Authorization"] = "Basic $(base64encode(userinfo(uri)))"
        @log "adding basic authentication header"
    end
    if isa(b, Dict) || isa(b, Form)
        # form data
        body = Form(b)
        headers["Content-Type"] = "multipart/form-data; boundary=$(body.boundary)"
    else
        body = FIFOBuffer(b)
    end
    if iscompressed(body) && length(body) > get(options, :chunksize, 0)
        options.chunksize = length(body) + 1
    end
    if !haskey(headers, "Content-Type") && length(body) > 0 && !isa(body, Form)
        sn = sniff(body)
        headers["Content-Type"] = sn
        @log "setting Content-Type header to: $sn"
    end
    return Request(m, Int16(1), Int16(1), uri, merge!(headers, makeheaders(userheaders)), body)
end

Request(method, uri, h=Headers(), body=""; options::RequestOptions=RequestOptions(), logger::Option{IO}=STDOUT, verbose::Bool=false) =
    Request(convert(HTTP.Method, method),
            isa(uri, String) ? URI(uri; isconnect=(method == "CONNECT" || method == CONNECT)) : uri,
            h, body; options=options, logger=logger, verbose=verbose)

Request(; method::Method=GET, major::Integer=Int16(1), minor::Integer=Int16(1), uri=URI(""), headers=Headers(), body=FIFOBuffer("")) =
    Request(method, major, minor, uri, headers, body)

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
    Response(status::Integer)
    Response(status::Integer, body::String)
    Response(status::Integer, headers, body)
    Response(; status=200, cookies=HTTP.Cookie[], headers=HTTP.Headers(), body="")

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
  * `String(r)`: consume the response body, returning it as a `String`
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
function Base.String(r::Union{Request, Response})
    if contains(Base.get(headers(r), "Content-Type", ""), "ISO-8859-1")
        return iso8859_1_to_utf8(String(body(r)))
    else
        return String(body(r))
    end
end

Response(; status::Int=200,
         cookies::Vector{Cookie}=Cookie[],
         headers::Headers=Headers(),
         body::FIFOBuffer=FIFOBuffer(""),
         request::Nullable{Request}=Nullable{Request}(),
         history::Vector{Response}=Response[]) =
    Response(status, Int16(1), Int16(1), cookies, headers, body, request, history)

Response(n::Integer, r::Request) = Response(; body=FIFOBuffer(n), request=Nullable(r))
Response(s::Integer) = Response(; status=s)
Response(s::Integer, msg) = Response(; status=s, body=FIFOBuffer(msg))
Response(b::Union{Vector{UInt8}, String}) = Response(; headers=defaultheaders(Response), body=FIFOBuffer(b))
Response(s::Integer, h::Headers, body) = Response(; status=s, headers=h, body=FIFOBuffer(body))

defaultheaders(::Type{Response}) = Headers(
    "Server"            => "Julia/$VERSION",
    "Content-Type"      => "text/html; charset=utf-8",
    "Content-Language"  => "en",
    "Date"              => Dates.format(Dates.now(Dates.UTC), Dates.RFC1123Format)
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
function headers(io::IO, r::Union{Request, Response})
    for (k, v) in headers(r)
        write(io, "$k: $v$CRLF")
    end
    # write(io, CRLF); we let the body write this in case of chunked transfer
end

# body
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
hasmessagebody(r::Request) = length(r.body) > 0 && !(r.method in (GET, HEAD, CONNECT))

function body(io::IO, r::Union{Request, Response}, opts)
    if !hasmessagebody(r)
        write(io, "$CRLF")
        return
    end
    chksz = get(opts, :chunksize, 0)
    pos = position(r.body)
    @sync begin
        @async begin
            chunked = false
            bytes = UInt8[]
            while !eof(r.body)
                bytes = chksz == 0 ? read(r.body) : read(r.body, chksz)
                eof(r.body) && !chunked && break
                if !chunked
                    write(io, "Transfer-Encoding: chunked$CRLF$CRLF")
                end
                chunked = true
                chunk = length(bytes)
                chunk == 0 && break
                write(io, "$(hex(chunk))$CRLF")
                write(io, bytes, CRLF)
            end
            if chunked
                write(io, "$(hex(0))$CRLF$CRLF")
            else
                write(io, "Content-Length: $(dec(length(bytes)))$CRLF$CRLF")
                write(io, bytes)
            end
        end
    end
    seek(r.body, pos)
    return
end

Base.write(io::IO, r::Union{Request, Response}, opts) = write(io, string(r))
function Base.string(r::Union{Request, Response}, opts=RequestOptions())
    i = IOBuffer()
    startline(i, r)
    headers(i, r)
    lb = opts.logbody
    if lb === nothing || lb
        body(i, r, opts)
    else
        println(i, "\n[request body logging disabled]\n")
    end
    return String(take!(i))
end

function Base.show(io::IO, r::Union{Request,Response}; opts=RequestOptions())
    println(io, typeof(r), ":")
    println(io, "\"\"\"")
    startline(io, r)
    headers(io, r)
    buf = IOBuffer()
    if isopen(r.body)
        println(io, "\n[open HTTP.FIFOBuffer with $(length(r.body)) bytes to read]")
    else
        body(buf, r, opts)
        b = take!(buf)
        if length(b) > 2
            contenttype = sniff(b)
            if contenttype in DISPLAYABLE_TYPES
                if length(b) > 750
                    println(io, "\n[$(typeof(r)) body of $(length(b)) bytes]")
                    println(io, String(b)[1:750])
                    println(io, "⋮")
                else
                    print(io, String(b))
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
    end
    print(io, "\"\"\"")
end
