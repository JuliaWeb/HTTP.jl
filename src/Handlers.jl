"""
The `HTTP.Handlers` module provides a middleware framework in conjuction with the `HTTP.Servers` server module.

The core interface function is:
```julia
handle(handler::Handler, request) => HTTP.Response
```

An http server is started by calling `HTTP.listen(handler::Union{Function, Handler}, ...)` and when a http request
is received, it is "handled" by the handler by calling `HTTP.handle(handler, request)`.

The `Handlers` framework is built to be extensible. It's very easy to chain handlers together to form a 
"middleware stack" of handler layers, or even define a custom handler type that could be re-used by others.

See `?HTTP.Servers` for an extended example of a server + custom handler framework usage
"""
module Handlers

export handle, Handler, RequestHandler, StreamHandler,
       RequestHandlerFunction, StreamHandlerFunction

using ..Messages, ..Streams, ..IOExtras

"""
handle(handler::Handler, request) => Response

Function used to dispatch to a Handler. Called from the core HTTP.listen method with the
initial Handler passed to `HTTP.listen(handler, ...)`.
"""
function handle end

"""
Abstract type representing an object that knows how to "handle" an http request and return an appropriate
http response.

Types of builtin handlers provided by the HTTP package include:
  * `HTTP.RequestHandlerFunction`: a julia function of the form `f(request::HTTP.Request)`
  * `HTTP.Router`: pattern matches request url paths to be handled by registered `Handler`s
  * `HTTP.StreamHandlerFunction`: a julia function of the form `f(stream::HTTP.Stream)`
"""
abstract type Handler end

"""
Abstract type representing objects that handle `HTTP.Request` and return `HTTP.Response` objects.

See `?HTTP.RequestHandlerFunction` for an example of a concrete implementation.
"""
abstract type RequestHandler <: Handler end
"""
Abstract type representing objects that handle `HTTP.Stream` objects directly.

See `?HTTP.StreamHandlerFunction` for an example of a concrete implementation.
"""
abstract type StreamHandler <: Handler end

Handler(h::Handler) = h
Handler(f::Base.Callable) = RequestHandlerFunction(f)

"""
RequestHandlerFunction(f::Function)

A Function-wrapper type that is a subtype of `RequestHandler`. Takes a single Function as an argument.
The provided argument should be of the form `f(request) => Response`, i.e. it accepts a `Request` returns a `Response`.
"""
struct RequestHandlerFunction{F <: Base.Callable} <: RequestHandler
    func::F # func(req)
end
RequestHandlerFunction(f::RequestHandlerFunction) = f

"A default 404 Handler"
const FourOhFour = RequestHandlerFunction(req -> Response(404))

handle(h::RequestHandlerFunction, req::Request) = h.func(req)

"""
StreamHandlerFunction(f::Function)

A Function-wrapper type that is a subtype of `StreamHandler`. Takes a single Function as an argument.
The provided argument should be of the form `f(stream) => Nothing`, i.e. it accepts a raw `HTTP.Stream`,
handles the incoming request, writes a response back out to the stream directly, then returns.
"""
struct StreamHandlerFunction{F <: Base.Callable} <: StreamHandler
    func::F # func(stream)
end

handle(h::StreamHandlerFunction, stream::Stream) = h.func(stream)

end # module
