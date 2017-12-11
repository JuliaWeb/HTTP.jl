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
