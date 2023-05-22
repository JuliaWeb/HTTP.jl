# Server

For server-side functionality, HTTP.jl provides a robust framework for core
HTTP and websocket serving, flexible handler and middleware interfaces, and
low-level access for unique workflows. The core server listening code is in
the [`/src/Servers.jl`](https://github.com/JuliaWeb/HTTP.jl/blob/master/src/Servers.jl) file, while the handler, middleware, router, and 
higher level `HTTP.serve` function are defined in the [`/src/Handlers.jl`](https://github.com/JuliaWeb/HTTP.jl/blob/master/src/Handlers.jl)
file.

## `HTTP.serve`

`HTTP.serve`/`HTTP.serve!` are the primary entrypoints for HTTP server functionality, while `HTTP.listen`/`HTTP.listen!` are considered the lower-level core server loop methods that only operate directly with `HTTP.Stream`s. `HTTP.serve` is also built directly integrated with the `Handler` and `Middleware` interfaces and provides easy flexibility by doing so. The signature is:

```julia
HTTP.serve(f, host, port; kw...)
HTTP.serve!(f, host, port; kw...) -> HTTP.Server
```

Where `f` is a `Handler` function, typically of the form `f(::Request) -> Response`, but can also operate directly on an `HTTP.Stream` of the form `f(::Stream) -> Nothing` while also passing `stream=true` to the keyword arguments. The `host` argument should be a `String`, or `IPAddr`, created like `ip"0.0.0.0"`. `port` should be a valid port number as an `Integer`.
`HTTP.serve` is the blocking server method, whereas `HTTP.serve!` is non-blocking and returns
the listening `HTTP.Server` object that can be `close(server)`ed manually.

Supported keyword arguments include:
 * `sslconfig=nothing`, Provide an `MbedTLS.SSLConfig` object to handle ssl
    connections. Pass `sslconfig=MbedTLS.SSLConfig(false)` to disable ssl
    verification (useful for testing). Construct a custom `SSLConfig` object
    with `MbedTLS.SSLConfig(certfile, keyfile)`.
 * `tcpisvalid = tcp->true`, function `f(::TCPSocket)::Bool` to check if accepted
    connections are valid before processing requests. e.g. to do source IP filtering.
 * `readtimeout::Int=0`, close the connection if no data is received for this
    many seconds. Use readtimeout = 0 to disable.
 * `reuseaddr::Bool=false`, allow multiple servers to listen on the same port.
    Not supported on some OS platforms. Can check `HTTP.Servers.supportsreuseaddr()`.
 * `server::Base.IOServer=nothing`, provide an `IOServer` object to listen on;
    allows manually closing or configuring the server socket.
 * `verbose::Union{Int,Bool}=false`, log connection information to `stdout`. Use `-1`
    to also silence the server start and stop logs.
 * `access_log::Function`, function for formatting access log messages. The
    function should accept two arguments, `io::IO` to which the messages should
    be written, and `http::HTTP.Stream` which can be used to query information
    from. See also [`@logfmt_str`](@ref).
 * `on_shutdown::Union{Function, Vector{<:Function}, Nothing}=nothing`, one or
    more functions to be run if the server is closed (for example by an
    `InterruptException`). Note, shutdown function(s) will not run if an
    `IOServer` object is supplied to the `server` keyword argument and closed
    by `close(server)`.

## `HTTP.Handler`

Abstract type for the handler interface that exists for documentation purposes.
A `Handler` is any function of the form `f(req::HTTP.Request) -> HTTP.Response`.
There is no requirement to subtype `Handler` and users should not rely on or dispatch
on `Handler`. A `Handler` function `f` can be passed to [`HTTP.serve`](@ref)
wherein a server will pass each incoming request to `f` to be handled and a response
to be returned. Handler functions are also the inputs to [`Middleware`](@ref) functions
which are functions of the form `f(::Handler) -> Handler`, i.e. they take a `Handler`
function as input, and return a "modified" or enhanced `Handler` function.

For advanced cases, a `Handler` function can also be of the form `f(stream::HTTP.Stream) -> Nothing`.
In this case, the server would be run like `HTTP.serve(f, ...; stream=true)`. For this use-case,
the handler function reads the request and writes the response to the stream directly. Note that
any middleware used with a stream handler also needs to be of the form `f(stream_handler) -> stream_handler`,
i.e. it needs to accept a stream `Handler` function and return a stream `Handler` function.

## `HTTP.Middleware`

Abstract type for the middleware interface that exists for documentation purposes.
A `Middleware` is any function of the form `f(::Handler) -> Handler` (ref: [`Handler`](@ref)).
There is no requirement to subtype `Middleware` and users should not rely on or dispatch
on the `Middleware` type. While `HTTP.serve(f, ...)` requires a _handler_ function `f` to be
passed, middleware can be "stacked" to create a chain of functions that are called in sequence,
like `HTTP.serve(base_handler |> cookie_middleware |> auth_middlware, ...)`, where the
`base_handler` `Handler` function is passed to `cookie_middleware`, which takes the handler
and returns a "modified" handler (that parses and stores cookies). This "modified" handler is
then an input to the `auth_middlware`, which further enhances/modifies the handler.

## `HTTP.Router`

Object part of the `Handler` framework for routing requests based on path matching registered routes.

```julia
r = HTTP.Router(_404, _405)
```

Define a router object that maps incoming requests by path to registered routes and
associated handlers. Paths can be registered using [`HTTP.register!`](@ref). The router
object itself is a "request handler" that can be called like:
```
r = HTTP.Router()
resp = r(request)
```

Which will inspect the `request`, find the matching, registered handler from the url,
and pass the request on to be handled further.

See [`HTTP.register!`](@ref) for additional information on registering handlers based on routes.

If a request doesn't have a matching, registered handler, the `_404` handler is called which,
by default, returns a `HTTP.Response(404)`. If a route matches the path, but not the method/verb
(e.g. there's a registered route for "GET /api", but the request is "POST /api"), then the `_405`
handler is called, which by default returns `HTTP.Response(405)` (method not allowed).

## `HTTP.listen`

Lower-level core server functionality that only operates on `HTTP.Stream`. Provides a level of separation from `HTTP.serve` and the `Handler` framework. Supports all the same arguments and keyword arguments as [`HTTP.serve`](@ref), but the handler function `f` _must_ take a single `HTTP.Stream` as argument. `HTTP.listen!` is the non-blocking counterpart to `HTTP.listen` (like `HTTP.serve!` is to `HTTP.serve`).

## Log formatting

Nginx-style log formatting is supported via the [`HTTP.@logfmt_str`](@ref) macro and can be passed via the `access_log` keyword argument for [`HTTP.listen`](@ref) or [`HTTP.serve`](@ref).

## Serving on the interactive thead pool

Beginning in Julia 1.9, the main server loop is spawned on the [interactive threadpool](https://docs.julialang.org/en/v1.9/manual/multi-threading/#man-threadpools) by default. If users do a Threads.@spawn from a handler, those threaded tasks should run elsewhere and not in the interactive threadpool, keeping the web server responsive.

Note that just having a reserved interactive thread doesn’t guarantee CPU cycles, so users need to properly configure their running Julia session appropriately (i.e. ensuring non-interactive threads available to run tasks, etc).