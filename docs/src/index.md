# HTTP.jl Documentation

## Overview

HTTP.jl provides both client and server functionality for the [http](https://en.wikipedia.org/wiki/Hypertext_Transfer_Protocol) and [websocket](https://en.wikipedia.org/wiki/WebSocket) protocols. As a client, it provides the ability to make a wide range of
requests, including GET, POST, websocket upgrades, form data, multipart, chunking, and cookie handling. There is also advanced functionality to provide client-side middleware and generate your own customized HTTP client.
On the server side, it provides the ability to listen, accept, and route http requests, with middleware and
handler interfaces to provide flexibility in processing responses.

## Quickstart

### Making requests (client)

[`HTTP.request`](@ref) sends an http request and returns a response.

```julia
# make a GET request, both forms are equivalent
resp = HTTP.request("GET", "http://httpbin.org/ip")
resp = HTTP.get("http://httpbin.org/ip")
println(resp.status)
println(String(resp.body))

# make a POST request, sending data via `body` keyword argument
resp = HTTP.post("http://httpbin.org/body"; body="request body")

# make a POST request, sending form-urlencoded body
resp = HTTP.post("http://httpbin.org/body"; body=Dict("nm" => "val"))

# include query parameters in a request
# and turn on verbose logging of the request/response process
resp = HTTP.get("http://httpbin.org/anything"; query=["hello" => "world"], verbose=2)

# simple websocket client
WebSockets.open("ws://websocket.org") do ws
    # we can iterate the websocket
    # where each iteration yields a received message
    # iteration finishes when the websocket is closed
    for msg in ws
        # do stuff with msg
        # send back message as String, Vector{UInt8}, or iterable of either
        send(ws, resp)
    end
end
```

### Handling requests (server)

[`HTTP.serve`](@ref) allows specifying middleware + handlers for how incoming requests should be processed.

```julia
# authentication middleware to ensure property security
function auth(handler)
    return function(req)
        ident = parse_auth(req)
        if ident === nothing
            # failed to security authentication
            return HTTP.Response(401, "unauthorized")
        else
            # store parsed identity in request context for handler usage
            req.context[:auth] = ident
            # pass request on to handler function for further processing
            return handler(req)
        end
    end
end

# handler function to return specific user's data
function handler(req)
    ident = req.context[:auth]
    return HTTP.Response(200, get_user_data(ident))
end

# start a server listening on port 8081 (default port) for localhost (default host)
# requests will first be handled by teh auth middleware before being passed to the `handler`
# request handler function
HTTP.serve(auth(handler))

# websocket server is very similar to client usage
WebSockets.listen("0.0.0.0", 8080) do ws
    for msg in ws
        # simple echo server
        send(ws, msg)
    end
end
```

## Further Documentation

Check out the client, server, and websocket-specific documentation pages for more in-depth discussions
and examples for the many configurations available.

```@contents
Pages = ["client.md", "server.md", "websockets.md", "reference.md"]
```

## Migrating Legacy Code to 1.0

The 1.0 release is finally here! It's been a lot of work over the course of about 9 months combing through every part of the codebase to try and modernize APIs, fix long-standing issues, and bring the level of functionality up to par with other language http implementations. Along the way, some breaking changes were made, but with the aim that the package will now be committed to current published APIs for a long time to come. With the amount of increased functionality and fixes, we hope it provides enough incentive to make the update; as always, if you run into issues upgrading or feel something didn't get polished or fixed quite right, don't hesitate to [open an issue](https://github.com/JuliaWeb/HTTP.jl/issues/new) so we can help.

The sections below outline a mix of breaking changes that were made, in addition to some of the new features in 1.0 with the aim to help those updating legacy codebases.

### Struct Changes

  * The `HTTP.Request` and `HTTP.Response` `body` fields are not restricted to `Vector{UInt8}`; if a `response_stream` is passed to `HTTP.request`, it will be set as the `resp.body` (previously the body was an empty `UInt8[]`). This simplified many codepaths so these "other body object types" didn't have to be held in some other state, but could be stored in the `Request`/`Response` directly. It also opens up the possibility, (as shown in the [Cors Server](@ref) example), where middleware can serialize/deserialize to/from the `body` field directly.
  * In related news, a `Request` body can now be passed as a `Dict` or `NamedTuple` to have the key-value pairs serialized in the `appliction/x-www-form-urlencoded` Content-Type matching many other libraries functionality
  * Responses with the `Transfer-Encoding: gzip` header will now also be automatically decompressed, and this behavior is configurable via the `decompress::Bool` keyword argument for `HTTP.request`
  * If a `response_stream` is provided for streaming a request's response body, `HTTP.request` will not call `close` before returning, leaving that up to the caller.
  In addition, in the face of redirects or retried requests, note the `response_stream` will not be written to until the *final* response is received.
  * If a streaming request `body` is provided, it should support the `mark`/`reset` methods in case the request needs to be retried.
  * Users are encouraged to access the publicly documented fields of `Request`/`Response` instead of the previously documented "accessor" functions; these fields are now committed as the public API, so feel free to do `resp.body` instead of `HTTP.body(resp)`. The accessor methods are still defined for backwards compat.
  * The `Request` object now stores the original `url` argument provided to `HTTP.request` as a parsed `URIs.URI` object, and accessed via the `req.url` field. This is commonly desired in handlers/middleware, so convenient to keep it around.
  * The `Request` object also has a new `req.context` field of type `Dict{Symbol, Any}` for storing/sharing state between handler/middleware layers. For example, the `HTTP.Router` now parses and stores named path parameters with the `:params` key in the context for handlers to access. Another `HTTP.cookie_middleware` will parse and store any request `Cookie` header in the `:cookies` context key.
  * `HTTP.request` now throws more consistent and predictable error types, including (and restricted to): `HTTP.ConnectError`, `HTTP.StatusError`, `HTTP.TimeoutError`, and `HTTP.RequestError`. See the [Request exceptions](@ref) section for more details on each exception type.
  * Cookie persistence used to use a `Dict` per thread to store domain-specific cookie sessions. A new threadsafe `CookieJar` struct now globally manages cookie persistence by default. Users can still construct and pass their own `cookiejar` keyword argument to `HTTP.request` if desired.

### Keyword Argument Changes

  * The `pipeline_limit` keyword argument (and support for it) were removed in `HTTP.request`; the implementation was poor and it drastically complicated the request internal implementation. In addition, it's not commonly supported in other modern http implementations, which encourage use of HTTP/2 for better designed functionality.
  * `reuse_limit` support was removed in both `HTTP.request` and `HTTP.listen`; another feature that complicated code more than it was actually useful and hence removed.
  * `aws_authentication` and its related keyword arguments have been removed in favor of using the AWS.jl package
  * A new `redirect_method` keyword argument exists and supports finer-grained control over which method to use in the case of a request redirect

### Other Largish Changes

#### "Handlers" framework overhaul

The server-side Handlers framework has been changed to a more modern and flexible framework, including the [`Handler`](@ref) and [`Middleware`](@ref) interfaces. It's similar in ways to the old interfaces, but in our opinion, simpler and more straightforward with the clear distinction/pattern between what a `Handler` does vs. a `Middlware`.

In that vein, `HTTP.Handlers.handle` has been removed. `HTTP.serve` expects a single request or stream `Handler` function, which should be of the form `f(::Request)::Response` for the request case, or `f(::Stream)::Nothing` for streams.

There are also plans to either include some common useful middleware functions in HTTP.jl directly, or a sister package specifically for collecting useful middlewares people can reuse.

### WebSockets overhaul

The WebSockets code was some of the oldest and least maintained code in HTTP.jl. It was debated removing it entirely, but there aren't really other modern implementations that are well-maintained. So the WebSockets code was overhauled, modernized, and is now tested against the industry standard autobahn test suite (yay for 3rd party verification!). The API changed as well; while `WebSockets.open` and `WebSockets.listen` have stayed the same, the `WebSocket` object itself now doesn't subtype `IO` and has a restricted interface like:
  * `ws.id` access a unique generated UUID id for this websocket connection
  * `receive(ws)` receive a single non-control message on a websocket, returning a `String` or `Vector{UInt8}` depending on whether the message was sent as TEXT or BINARY
  * `send(ws, msg)` send a message; supports TEXT and BINARY messages, and can provide an iterable for `msg` to send fragmented messages
  * `close(ws)` close a websocket connection
  * For convenience, a `WebSocket` object can be iterated, where each iteration yields a non-control message and iteration terminates when the connection is closed

### HTTP.Router reimplementation

While clever, the old `HTTP.Router` implementation relied on having routes registered "statically", which can be really inconvenient for any cases where the routes are generated programmatically or need to be set/updated dynamically.

The new `HTTP.Router` implementation uses a text-matching based trie data structure on incoming request path segments to find the right matching handler to process the request. It also supports parsing and storing path variables, like `/api/{id}` or double wildcards for matching trailing path segments, like `/api/**`.

`HTTP.Router` now also supports complete unrestricted route registration via `HTTP.register!`.

### Internal client-side layers overhaul

While grandiose in vision, the old type-based "layers" framework relied heavily on type parameter abuse for generating a large "stack" of layers to handle different parts of each `HTTP.request`. The new framework actually matches very closely with the server-side `Handler` and `Middleware` interfaces, and can be found in more detail under the [Client-side Middleware (Layers)](@ref) section of the docs. The new implementation, while hopefully bringing greater consistency between client-side and server-side frameworks, is much simpler and forced a large cleanup of state-handling in the `HTTP.request` process for the better.

In addition to the changing of all the client-side layer definitions, `HTTP.stack` now behaves slightly different in returning the new "layer" chain for `HTTP.request`, while also accepting custom request/stream layers is provided. A new `HTTP.@client` macro is provided for convenience in the case that users want to write a custom client-side middleware/layer and wrap its usage in an HTTP.jl-like client.

There also existed a few internal methods previously for manipulating the global stack of client-side layers (insert, insert_default!, etc.). These have been removed and replaced with a more formal (and documented) API via `HTTP.pushlayer!` and `HTTP.poplayer!`. These can be used to globally manipulate the client-side stack of layers for any `HTTP.request` that is made.
