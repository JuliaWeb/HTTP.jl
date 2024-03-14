# Client

HTTP.jl provides a wide range of HTTP client functionality, mostly exposed through the [`HTTP.request`](@ref) family of functions. This document aims to walk through the various ways requests can be configured to accomplish whatever your goal may be.

## Basic Usage

The standard form for making requests is:

```julia
HTTP.request(method, url [, headers [, body]]; <keyword arguments>]) -> HTTP.Response
```

First, let's walk through the positional arguments.

### Method

`method` refers to the HTTP method (sometimes known as "verb"), including GET, POST, PUT, DELETE, PATCH, TRACE, etc. It can be provided either as a `String` like `HTTP.request("GET", ...)`, or a `Symbol` like `HTTP.request(:GET, ...)`. There are also convenience methods for the most common methods:
  * `HTTP.get(...)`
  * `HTTP.post(...)`
  * `HTTP.put(...)`
  * `HTTP.delete(...)`
  * `HTTP.patch(...)`
  * `HTTP.head(...)`

These methods operate identically to `HTTP.request`, except the `method` argument is "builtin" via function name.

### Url

For the request `url` argument, the [URIs.jl](https://github.com/JuliaWeb/URIs.jl) package is used to parse this `String` argument into a `URI` object, which detects the HTTP scheme, user info, host, port (if any), path, query parameters, fragment, etc. The host and port will be used to actually make a connection to the remote server and send data to and receive data from. Query parameters can be included in the `url` `String` itself, or passed as a separate [`query`](@ref) keyword argument to `HTTP.request`, which will be discussed in more detail later.

### Headers

The `headers` argument is an optional list of header name-value pairs to be included in the request. They can be provided as a `Vector` of `Pair`s, like `["header1" => "value1", "header2" => "value2"]`, or a `Dict`, like `Dict("header1" => "value1", "header2" => "value2")`. Header names do not have to be unique, so any argument passed will be converted to `Vector{Pair}`. By default, `HTTP.request` will include a few headers automatically, including `"Host" => url.host`, `"Accept" => "*/*"`, `"User-Agent" => "HTTP.jl/1.0"`, and `"Content-Length" => body_length`. These can be overwritten by providing them yourself, like `HTTP.get(url, ["Accept" => "application/json"])`, or you can prevent the header from being included by default by including it yourself with an empty string as value, like `HTTP.get(url, ["Accept" => ""])`, following the curl convention. There are keyword arguments that control the inclusion/setting of other headers, like `basicauth`, `detect_content_type`, `cookies`, etc. that will be discussed in more detail later.

### Body

The optional `body` argument makes up the "body" of the sent request and is only used for HTTP methods that expect a body, like POST and PUT. A variety of objects are supported:
  * a `Dict` or `NamedTuple` to be serialized as the "application/x-www-form-urlencoded" content type, so `Dict("nm" => "val")` will be sent in the request body like `nm=val`
  * any `AbstractString` or `AbstractVector{UInt8}` which will be sent "as is" for the request body
  * a readable `IO` stream or any `IO`-like type `T` for which `eof(T)` and `readavailable(T)` are defined. This stream will be read and sent until `eof` is `true`. This object should support the `mark`/`reset` methods if request retires are desired (if not, no retries will be attempted).
  * Any collection or iterable of the above (`Dict`, `AbstractString`, `AbstractVector{UInt8}`, or `IO`) which will result in a "Transfer-Encoding=chunked" request body, where each iterated element will be sent as a separate chunk
  * a [`HTTP.Form`](@ref), which will be serialized as the "multipart/form-data" content-type

### Response

Upon successful completion, `HTTP.request` returns a [`HTTP.Response`](@ref) object. It includes the following fields:
  * `status`: the HTTP status code of the response, e.g. `200` for normal response
  * `headers`: a `Vector` of `String` `Pair`s for each name=value pair in the response headers. Convenience methods for working with headers include: `HTTP.hasheader(resp, key)` to check if header exists; `HTTP.header(resp, key)` retrieve the value of a header with name `key`; `HTTP.headers(resp, key)` retrieve a list of all the headers with name `key`, since headers can have duplicate names
  * `body`: a `Vector{UInt8}` of the response body bytes. Alternatively, an `IO` object can be provided via the [`response_stream`](@ref) keyword argument to have the response body streamed as it is received.

## Keyword Arguments

A number of keyword arguments are provided to give fine-tuned control over the request process.

### `query`

Query parameters are included in the url of the request like `http://httpbin.org/anything?q1=v1&q2=v2`, where the string `?q1=v1&q2=v2` after the question mark represent the "query parameters". They are essentially a list of key-value pairs. Query parameters can be included in the url itself when calling `HTTP.request`, like `HTTP.request(:GET, "http://httpbin.org/anything?q1=v1&q2=v2")`, but oftentimes, it's convenient to generate and pass them programmatically. To do this, pass an object that iterates `String` `Pair`s to the `query` keyword argument, like the following examples:
  * `HTTP.get(url; query=Dict("x1" => "y1", "x2" => "y2")`
  * `HTTP.get(url; query=["x1" => "y1", "x1" => "y2"]`: this form allows duplicate key values
  * `HTTP.get(url; query=[("x1", "y1)", ("x2", "y2")]`

### `response_stream`

By default, the `HTTP.Response` body is returned as a `Vector{UInt8}`. There may be scenarios, however, where more control is desired, like downloading large files, where it's preferable to stream the response body directly out to file or into some other `IO` object. By passing a writeable `IO` object to the `response_stream` keyword argument, the response body will not be fully materialized and will be written to as it is received from the remote connection. Note that in the presence of request redirects and retries, multiple requests end up being made in a single call to `HTTP.request` by default (configurable via the [`redirects`](@ref) and [`retry`](@ref) keyword arguments). If `response_stream` is provided and a request is redirected or retried, the `response_stream` is not written to until the *final* request is completed (either the redirect is successfully followed, or the request doesn't need to be retried, etc.).

#### Examples

Stream body to file:
```julia
io = open("get_data.txt", "w")
r = HTTP.request("GET", "http://httpbin.org/get", response_stream=io)
close(io)
println(read("get_data.txt", String))
```

Stream body through buffer:
```julia
r = HTTP.get("http://httpbin.org/get", response_stream=IOBuffer())
println(String(take!(r.body)))
```

### `verbose`

HTTP requests can be a pain sometimes. We get it. It can be tricky to get the headers, query parameters, or expected body in just the right format. For convenience, the `verbose` keyword argument is provided to enable debug logging for the duration of the call to `HTTP.request`. This can be helpful to "peek under the hood" of what all goes on in the process of making request: are redirects returned and followed? Is the connection not getting made to the right host? Is some error causing the request to be retried unexpectedly? Currently, the `verbose` keyword argument supports passing increasing levels to enable more and more verbose logging, from `0` (no debug logging, the default), up to `3` (most verbose, probably too much for anyone but package developers).

If you're running into a real head-scratcher, don't hesitate to [open an issue](https://github.com/JuliaWeb/HTTP.jl/issues/new) and include the problem you're running into; it's most helpful when you can include the output of passing `verbose=3`, so package maintainers can see a detailed view of what's going on.

### Connection keyword arguments

#### `connect_timeout`

When a connection is attempted to a remote host, sometimes the connection is unable to be established for whatever reason. Passing a non-zero `connect_timetout` value will cause `HTTP.request` to wait that many seconds before giving up and throwing an error.

#### `pool`

Many remote web services/APIs have rate limits or throttling in place to avoid bad actors from abusing their service. They may prevent too many requests over a time period or they may prevent too many connections being simultaneously open from the same client. By default, when `HTTP.request` opens a remote connection, it remembers the exact host:port combination and will keep the connection open to be reused by subsequent requests to the same host:port. The `pool` keyword argument specifies a specific `HTTP.Pool` object to be used for controlling the maximum number of concurrent connections allowed to be happening across the pool. It's constructed via `HTTP.Pool(max::Int)`. Requests attempted when the maximum is already hit will block until previous requests finish. The `idle_timeout` keyword argument can be passed to `HTTP.request` to control how long it's been since a connection was lasted used in order to be considered 'valid'; otherwise, "stale" connections will be discarded.

#### `readtimeout`

After a connection is established and a request is sent, a response is expected. If a non-zero value is passed to the `readtimeout` keyword argument, `HTTP.request` will wait to receive a response that many seconds before throwing an error. Passing `readtimeout = 0` disables any timeout checking and is the default.

### `status_exception`

When a non-2XX HTTP status code is received in a response, this is meant to convey some error condition. 3XX responses typically deal with "redirects" where the request should actually try a different url (these are followed automatically by default in `HTTP.request`, though up to a limit; see [`redirect`](@ref)). 4XX status codes typically mean the remote server thinks something is wrong in how the request is made. 5XX typically mean something went wrong on the server-side when responding. By default, as mentioned previously, `HTTP.request` will attempt to follow redirect responses, and retry "retryable" requests (where the status code and original request method allow). If, after redirects/retries, a response still has a non-2XX response code, the default behavior is to throw an `HTTP.StatusError` exception to signal that the request didn't succeed. This behavior can be disabled by passing `status_exception=false`, where the `HTTP.Response` object will be returned with the non-2XX status code intact.

### `logerrors`

If `true`, `HTTP.StatusError`, `HTTP.TimeoutError`, `HTTP.IOError`, and `HTTP.ConnectError` will be logged via `@error` as they happen, regardless of whether the request is then retried or not. Useful for debugging or monitoring requests where there's worry of certain errors happening but ignored because of retries.

### `logtag`

If provided, will be used as the tag for error logging. Useful for debugging or monitoring requests.

### `observelayers`

If `true`, enables the `HTTP.observelayer` to wrap each client-side "layer" to track the amount of time spent in each layer as a request is processed. This can be useful for debugging performance issues. Note that when retries or redirects happen, the time spent in each layer is cumulative, as noted by the `[layer]_count`. The metrics are stored in the `Request.context` dictionary, and can be accessed like `HTTP.get(...).request.context`.

### `basicauth`

By default, if "user info" is detected in the request url, like `http://user:password@host`, the `Authorization: Basic` header will be added to the request headers before the request is sent. While not very common, some APIs use this form of authentication to verify requests. This automatic adding of the header can be disabled by passing `basicauth=false`.

### `canonicalize_headers`

In the HTTP specification, header names are case insensitive, yet it is sometimes desirable to send/receive headers in a more predictable format. Passing `canonicalize_headers=true` (false by default) will reformat all request *and* response headers to use the Canonical-Camel-Dash-Format.

### `proxy`

In certain network environments, connections to a proxy must first be made and external requests are then sent "through" the proxy. `HTTP.request` supports this workflow by allowing the passing of a proxy url via the `proxy` keyword argument. Alternatively, it's a common pattern for HTTP libraries to check for the `http_proxy`, `HTTP_PROXY`, `https_proxy`, `HTTPS_PROXY`, and `no_proxy` environment variables and, if present, be used for these kind of proxied requests. Note that environment variables typically should be set prior to starting the Julia process; alternatively, the `withenv` Julia function can be used to temporarily modify the current process environment variables, so it could be used like:

```julia
resp = withenv("http_proxy" => proxy_url) do
    HTTP.request(:GET, url)
end
```

The `no_proxy` argument is typically a comma-separated list of urls that should *not* use the proxy, and is parsed when the HTTP.jl package is loaded, and thus won't work with the `withenv` method mentioned.

### `detect_content_type`

By default, the `Content-Type` header is not included by `HTTP.request`. To automatically detect various content types (html, xml, pdf, images, zip, gzip, JSON) and set this header, pass `detect_content_type=true`.

### `decompress`

By default, when the response includes the `Content-Encoding: gzip` header, the response body will be decompressed. To avoid this behavior, pass `decompress=false`. This keyword also controls the automatic inclusion of the `Accept-Encoding: gzip` header in the request being sent.

### Retry arguments

#### `retry`

Controls overall whether requests will be retried at all; pass `retry=false` to disable all retries.

#### `retries`

Controls the total number of retries that will be attempted. Can also disable all retries by passing `retries = 0`. Note that for a request to be retried, in addition to the `retry` and `retries` keyword arguments, must be "retryable", which includes the following requirements:
  * Request body must be static (string or bytes) or an `IO` the supports the `mark`/`reset` interface
  * The request method must be idempotent as defined by RFC-7231, which includes GET, HEAD, OPTIONS, TRACE, PUT, and DELETE (not POST or PATCH).
  * If the method _isn't_ idempotent, can pass `retry_non_idempotent=true` keyword argument to retry idempotent requests
  * The retry limit hasn't been reached, as specified by `retries` keyword argument
  * The "failed" response must have one of the following status codes: 403, 408, 409, 429, 500, 502, 503, 504, 599.

#### `retry_non_idempotent`

By default, this keyword argument is `false`, which controls whether non-idempotent requests will be retried (POST or PATCH requests).

#### `retry_delays`

Allows providing a custom `ExponentialBackOff` object to control the delay between retries.
Default is `ExponentialBackOff(n = retries)`.

#### `retry_check`

Allows providing a custom function to control whether a retry should be attempted.
The function should accept 5 arguments: the delay state, exception, request, response (an `HTTP.Response` object *if* a request was successfully made, otherwise `nothing`), and `resp_body` response body (which may be `nothing` if there is no response yet, otherwise a `Vector{UInt8}`), and return `true` if a retry should be attempted. So in traditional nomenclature, the function would have the form `f(s, ex, req, resp, resp_body) -> Bool`.

### Redirect Arguments

#### `redirect`

This keyword argument controls whether responses that specify a redirect (via 3XX status code + `Location` header) will be "followed" by issuing a follow up request to the specified `Location`. There are certain rules/logic that are followed when deciding whether to redirect and _how_ the redirected request will be made:
  * The `Location` redirect url must be "valid" with an appropriate scheme and host; if the new location is relative to the original request url, the new url is resolved by calling `URIs.resolvereference`
  * The response status code is one of: 301, 302, 307, or 308
  * The method of the redirected request may change: 307 or 308 status codes will _not_ change the method, 303 means only a GET request is allowed, otherwise, if the `redirect_method` keyword argument is provided, it will be used. If not provided, the redirected request will default to a GET request.
  * We'll only make a redirect request if we haven't made too many redirect attempts already, as controlled by the `redirect_limit` keyword argument (default 3)
  * The original request headers will, by default, be forwarded in the redirected request, unless the new url is an entirely new host, then `Cookie` and `Authorization` headers will be removed.

#### `redirect_limit`

Controls how many redirects will be "followed" by making additional requests in the case of a redirected response url recursively returning redirect responses and so on. In addition to `redirect=false`, passing `redirect_limit=0` will also disable any redirect behavior all together.

#### `redirect_method`

May control the method that will be used in the redirected request. For 307 or 308 status codes, the same method will be used by default. For 303, only GET requests are allowed. For other status codes (301, 302), this keyword argument will be used to determine what the redirect request method will be. Passing `redirect_method=:same` will result in the same method as the original request. Otherwise, passing `redirect_method=:GET`, or any other valid method as `String` or `Symbol`, will result in that method for the redirected request.

#### `forwardheaders`

Controls whether original request headers will be included in the redirected request. `true` by default. Pass `forwardheaders=false` to disable headers being used in redirected requests. By design, if the new redirect location url is a different host than the original host, "sensitive" headers will not be forwarded, including `Cookie` and `Authorization` headers.

### SSL Arguments

#### `require_ssl_verification`

Controls whether the SSL configuration for a secure connection is verified in the handshake process. `true` by default. Should only be set to `false` if developing against a local server that can be completely trusted.

#### `sslconfig`

Allows specifying a custom `MbedTLS.SSLConfig` configuration to be used in the secure connection handshake process to verify the connection. A custom cert and key file can be passed to construct a custom `SSLConfig` like `MbedTLS.SSLConfig(cert_file, key_file)`.

### Cookie Arguments

#### `cookies`

Controls if and how a request `Cookie` header is set for a request. By default, `cookies` is `true`, which means the `cookiejar` (an internal global by default) will be checked for previously received `Set-Cookie` headers from past responses for the request domain and, if found, will be included in the outgoing request. Passing `cookies=false` will disable any automatic cookie tracking/setting. For more granular control, the `Cookie` header can be set manually in the `headers` request argument and `cookies=false` is passed. Otherwise, a `Dict{String, String}` can be passed in the `cookies` argument, which should be cookie name-value pairs to be serialized into the `Cookie` header for the current request. If `cookies=false` or an empty `Dict` is passed in the `cookies` keyword argument, no `Set-Cookie` response headers will be parsed and stored for use in future requests. In the automatic case of including previously received cookies, verification is done to ensure the cookie hasn't expired, matches the correct domain, etc.

#### `cookiejar`

If cookies are "enabled" (either by passing `cookies=true` or passing a non-empty `Dict` via `cookies` keyword argument), this keyword argument specifies the `HTTP.CookieJar` object that should be used to store received `Set-Cookie` cookie name-value pairs from responses. Cookies are stored for the appropriate host/domain and will, by default, be included in future requests when the host/domain match and other conditions are met (cookie hasn't expired, etc.). By default, a single global `CookieJar` is used, which is threadsafe. To pass a custom `CookieJar`, first create one: `jar = HTTP.CookieJar()`, then pass like `HTTP.get(...; cookiejar=jar)`.

## Streaming Requests

### `HTTP.open`

Allows a potentially more convenient API when the request and/or response bodies need to be streamed. Works like:

```julia
HTTP.open(method, url, [, headers]; kw...) do io
    write(io, body)
    [startread(io) -> HTTP.Response]
    while !eof(io)
        readavailable(io) -> AbstractVector{UInt8}
    end
end -> HTTP.Response
```

Where the `io` argument provided to the function body is an `HTTP.Stream` object, a custom `IO` that represents an open connection that is ready to be written to in order to send the request body, and/or read from to receive the response body. Note that `startread(io)` should be called before calling `readavailable` to ensure the response status line and headers are received and parsed appropriately. Calling `eof(io)` will return true until the response body has been completely received. Note that the returned `HTTP.Response` from `HTTP.open` will _not_ have a `.body` field since the body was read in the function body.

### Download

A [`download`](@ref) function is provided for similar functionality to `Downloads.download`.

## Client-side Middleware (Layers)

An `HTTP.Layer` is an abstract type to represent a client-side middleware.
A layer is any function of the form `f(::Handler) -> Handler`, where [`Handler`](@ref) is
a function of the form `f(::Request) -> Response`. Note that this `Handler` definition is the same from
the server-side documentation. It may also be apparent
that a `Layer` is the same as the [`Middleware`](@ref) interface from server-side, which is true, but
we define `Layer` to clarify the client-side distinction and its unique usage.

Creating custom layers can be a convenient way to "enhance" the `HTTP.request` process with custom functionality. It might be a layer that computes a special authorization header, or modifies the body in some way, or treats the response specially. Oftentimes, layers are application or domain-specific, where certain domain knowledge can be used to improve or simplify the request process. Layers can also be used to enforce the usage of certain keyword arguments if desired.

Custom layers can be deployed in one of two ways:
  * [`HTTP.@client`](@ref): Create a custom "client" with shorthand verb definitions, but which
    include custom layers; only these new verb methods will use the custom layers.
  * [`HTTP.pushlayer!`](@ref)/[`HTTP.poplayer!`](@ref): Allows globally adding and removing
    layers from the default HTTP.jl layer stack; *all* http requests will then use the custom layers

### Quick Examples
```julia
module Auth

using HTTP

function auth_layer(handler)
    # returns a `Handler` function; check for a custom keyword arg `authcreds` that
    # a user would pass like `HTTP.get(...; authcreds=creds)`.
    # We also accept trailing keyword args `kw...` and pass them along later.
    return function(req; authcreds=nothing, kw...)
        # only apply the auth layer if the user passed `authcreds`
        if authcreds !== nothing
            # we add a custom header with stringified auth creds
            HTTP.setheader(req, "X-Auth-Creds" => string(authcreds))
        end
        # pass the request along to the next layer by calling `auth_layer` arg `handler`
        # also pass along the trailing keyword args `kw...`
        return handler(req; kw...)
    end
end

# Create a new client with the auth layer added
HTTP.@client [auth_layer]

end # module

# Can now use custom client like:
Auth.get(url; authcreds=creds) # performs GET request with auth_layer layer included

# Or can include layer globally in all HTTP.jl requests
HTTP.pushlayer!(Auth.auth_layer)

# Now can use normal HTTP.jl methods and auth_layer will be included
HTTP.get(url; authcreds=creds)
```

For more ideas or examples on how client-side layers work, it can be useful to see how `HTTP.request` is built on layers internally, in the [`/src/clientlayers`](https://github.com/JuliaWeb/HTTP.jl/tree/master/src/clientlayers) source code directory.
