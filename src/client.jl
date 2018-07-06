using .Pairs


"""
    HTTP.Client(;args...)

A type to facilitate connections to remote hosts, send HTTP requests, and manage state between requests.
Additional keyword arguments can be passed that will get transmitted with each HTTP request:

  * `chunksize::Int`: if a request body is larger than `chunksize`, the "chunked-transfer" http mechanism will be used and chunks will be sent no larger than `chunksize`; default = `nothing`
  * `connecttimeout::Float64`: sets a timeout on how long to wait when trying to connect to a remote host; default = Inf. Note that while setting a timeout will affect the actual program control flow, there are current lower-level limitations that mean underlying resources may not actually be freed until their own timeouts occur (i.e. libuv sockets only timeout after 75 seconds, with no option to configure)
  * `readtimeout::Float64`: sets a timeout on how long to wait when receiving a response from a remote host; default = Int
  * `tlsconfig::TLS.SSLConfig`: a valid `TLS.SSLConfig` which will be used to initialize every https connection; default = `nothing`
  * `maxredirects::Int`: the maximum number of redirects that will automatically be followed for an http request; default = 5
  * `allowredirects::Bool`: whether redirects should be allowed to be followed at all; default = `true`
  * `forwardheaders::Bool`: whether user-provided headers should be forwarded on redirects; default = `true`
  * `retries::Int`: # of times a request will be tried before throwing an error; default = 3
  * `managecookies::Bool`: whether the request client should automatically store and add cookies from/to requests (following appropriate host-specific & expiration rules); default = `true`
  * `statusraise::Bool`: whether an `HTTP.StatusError` should be raised on a non-2XX response status code; default = `true`
  * `insecure::Bool`: whether an "https" connection should allow insecure connections (no TLS verification); default = `false`
  * `canonicalizeheaders::Bool`: whether header field names should be canonicalized in responses, e.g. `content-type` is canonicalized to `Content-Type`; default = `true`
  * `logbody::Bool`: whether the request body should be logged when `verbose=true` is passed; default = `true`
"""
mutable struct Client
    # cookies are stored in-memory per host and automatically sent when appropriate
    cookies::Dict{String, Set{Cookie}}
    # global request settings
    options::(VERSION > v"0.7.0-DEV.2338" ? NamedTuple : Vector{Pair{Symbol,Any}})
end

if VERSION > v"0.7.0-DEV.2338"
Client(;options...) = Client(Dict{String, Set{Cookie}}(), merge(NamedTuple(), options))
else
Client(;options...) = Client(Dict{String, Set{Cookie}}(), options)
end
global const DEFAULT_CLIENT = Client()

# build Request
function request(client::Client, method, url::URI;
                 headers=Header[],
                 body="",
                 query=nothing,
                 enablechunked::Bool=true,
                 stream::Bool=false,
                 verbose=false,
                 args...)

    # Add default values from client options to args...
    if VERSION > v"0.7.0-DEV.2338"
    args = merge(client.options, args)
    if query != nothing
       url = merge(url, query=query)
    end
    getarg = Base.get
    else
    for option in client.options
        defaultbyfirst(args, option)
    end
    getarg = getkv
    end
    newargs = Pair{Symbol,Any}[]

    if getarg(args, :chunksize, nothing) != nothing
        Base.depwarn(
        "The chunksize= option is deprecated and has no effect.\n" *
        "Use a HTTP.open and pass chunks of the desired size to `write`.",
        :chunksize)
    end

    if getarg(args, :connecttimeout, Inf) != Inf
        Base.depwarn(
        "The connecttimeout= is deprecated and has no effect.\n" *
        "See https://github.com/JuliaWeb/HTTP.jl/issues/114\n",
        :connecttimeout)
    end

    if getarg(args, :tlsconfig, nothing) != nothing
        Base.depwarn(
        "The tlsconfig= option is deprecated. Use sslconfig=::MbedTLS.SSLConfig",
        :tlsconfig)
        setkv(newargs, :sslconfig, getarg(args, :tlsconfig))
    end

    if getarg(args, :allowredirects, nothing) != nothing
        Base.depwarn(
        "The allowredirects= option is deprecated. Use redirect=::Bool",
        :allowredirects)
        setkv(newargs, :redirect, getarg(args, :allowredirects))
    end

    if getarg(args, :managecookies, nothing) != nothing
        Base.depwarn(
        "The managecookies= option is deprecated. Use cookies=::Bool",
        :managecookies)
        setkv(newargs, :cookies, getarg(args, :managecookies))
    end
    setkv(newargs, :cookiejar, client.cookies)

    if getarg(args, :statusraise, nothing) != nothing
        Base.depwarn(
        "The statusraise= options is deprecated. Use status_exception=::Bool",
        :statusraise)
        setkv(newargs, :status_exception, getarg(args, :statusraise))
    end

    if getarg(args, :insecure, nothing) != nothing
        Base.depwarn(
        "The insecure= option is deprecated. Use require_ssl_verification=::Bool",
        :insecure)
        setkv(newargs, :require_ssl_verification, !getarg(args, :insecure))
    end

    m = string(method)
    h = mkheaders(headers)
    if stream
        setkv(newargs, :response_stream, Base.BufferStream())
    end

    if isa(body, Dict)
        body = HTTP.Form(body)
        setbyfirst(h, "Content-Type" =>
                            "multipart/form-data; boundary=$(body.boundary)")
        setkv(newargs, :bodylength, length(body))
    end

    if !enablechunked && isa(body, IO)
        body = read(body)
    end

    if VERSION > v"0.7.0-DEV.2338"
    args = merge(args, newargs)
    else
    for newarg in newargs
        defaultbyfirst(args, newarg)
    end
    end

    return request(m, url, h, body; verbose=Int(verbose), args...)
end

for f in [:get, :post, :put, :delete, :head,
          :trace, :options, :patch, :connect]
    meth = f_str = uppercase(string(f))
    @eval begin
        ($f)(client::Client, url::URI; kw...) = request(client, $meth, url; kw...)
        ($f)(client::Client, url::AbstractString; kw...) = request(client, $meth, URI(url); kw...)
    end
    if !(f in [:get, :head])
        @eval begin
            ($f)(url::URI; kw...) = request(DEFAULT_CLIENT, $meth, url; kw...)
            ($f)(url::AbstractString; kw...) = request(DEFAULT_CLIENT, $meth, URI(url); kw...)
        end
    end
end
