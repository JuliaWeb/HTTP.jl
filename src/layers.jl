"""
The Layers module in the HTTP.jl package contains the internal machinery for how http client requests are actually made.

It exposes the concept of "layers" which are single components each responsible for handling
one "piece" of an http client request. Layers are linked together by each being required to
have a dedicated field to store the "next" layer in the stack to form a linked-list
where each layer has a window of execution when control is "passed" to it from the previous
layer in the stack.

Builtin to the HTTP.jl package, there are 4 "kinds" of layers that are characterized by
"where" they live in stack and the corresponding arguments they have access to when control is passed to them:
  * [`Layers.InitialLayer`](@ref): the "outermost" layers that receive arguments almost as-is provided from the calling user;
    arguments include the http `method`, `url`, `headers`, and `body`. The HTTP.jl-internal layer `MessageLayer` comes after the
    the last `Layers.InitialLayer` layer and transitions to the next layer kind
  * [`Layers.RequestLayer`](@ref): the `MessageLayer` took the `method`, `url`, and `headers` arguments and formed a full `HTTP.Request`
    object that layers in this "kind" now have access to; the `ConnectionPoolLayer` follows the last `RequestLayer` and opens a live
    connection to the remote server, transitioning us to the next layer kind
  * [`Layers.ConnectionLayer`](@ref): in addition to the `Request` object, we now also have access to the live/open `Connection` object
    which is connected to the remote; the `StreamLayer` follows the last `ConnectionLayer` layer to execute the actual request and read the response
  * [`Layers.ResponseLayer`](@ref): these are the "deepest" layers in the stack because they are only called after the request
    has been sent and a response has been received

So the rough flow of what actually happens when a user makes a call like `HTTP.get("https://google.com")` is as follows:
  * A "stack" of layers is made, starting with `ResponseLayer`s, then wrapping those in `ConnectionLayer`s, and so on to the outermost `InitialLayer`s
  * A little argument processing happens, but the request really begins execution with the first call to `Layers.request(layers, ctx, method, url, headers, body)`
  * This passes control to the outermost layer's `Layers.request` method, where it's responsible for, at a minimum, passing control on by calling `Layers.request(layer.next, ctx, method, url, headers, body)`
  * Conrol continues to pass down through the stack of layers until the `StreamLayer`, which physically sends the request and receives the response
  * Control then goes "back up" the stack starting with the `ResponseLayer`s all the way back to the outermost "first" `InitialLayer` layer before actually returning to the user

Ok, so why is all this important? Well, in addition to having a better understanding of what actually happens when you make a request,
this also provides necessary context for users who desire to _extend_ or _customize_ the request process.
Some examples of ways users may want to cusotmize:
  * Compute and add a required authentication header to every request made to a specific service/host
  * Provide configurable response "caching" given certain request inputs
  * Act as a "load balancer" where service names are mapped to an internal registry of physical IP addresses

We've already hinted in the explanations above about the requirements for implementing a proper layer,
so let's spell the interface out explicitly here:
  * Create a custom layer struct that subtypes one of 4 layer "kind" types:
    * `Layers.InitialLayer`
    * `Layers.RequestLayer`
    * `Layers.ConnectionLayer`
    * `Layers.ResponseLayer`
  * The custom layer struct MUST HAVE a dedicated field for storing the "next" layer in the stack; this usually looks something like:

```
struct CustomLayer{Next <: Layers.Layer} <: Layers.InitialLayer
    next::Next
    # additional fields...
end
```
  * There must be a constructor method of the form: `Layer(next; kw...)` where the `next` argument is some `Layers.Layer` subtype and must be stored in the above-mentioned required field
  * The custom layer must then overload the `Layers.request` method that corresponds to the layer "kind" they subtype:
    * `Layers.InitialLayer` => must overload: `Layers.request(layer::CustomLayer, ctx, method, url, headers, body)`
    * `Layers.RequestLayer` => must overload: `Layers.request(layer::CustomLayer, ctx, request, body)`
    * `Layers.ConnectionLayer` => must overload: `Layers.request(layer::CustomLayer, ctx, io, request, body)`
    * `Layers.ResponseLayer` => must overload: `Layers.request(layer::CustomLayer, ctx, response)`
  * The final requirement is that IN THE `Layers.request` overload, control MUST BE passed on to the next layer in the stack by, at some point, calling `Layers.request(layer.next, args...)`,
    where `layer.next` refers to the above-mentioned required field storing the "next" layer in the stack, and `args` are the SAME ARGUMENTS that were overloaded in the custom layer's `Layer.request`
    overloaded method.

Ok great, I think I've got a handle on how to go about creating my own custom layer (I can also poke around the many examples in
the HTTP.jl package itself, since they all implement this exact machinery). But once I have a custom layer, how do I USE IT? Or in
other words, how do I get it included in the request stack?

HTTP.jl provides the `HTTP.stack(layers...; kw...)` function that takes any number of custom layers as initial positional arguments,
along with _all_ keyword arguments passed from users, and returns the request stack that will immediately be passed to `Layers.request`.
So manually, if I had my `CustomLayer` all setup and defined, I could "include" it by doing something like:
```
resp = HTTP.request(HTTP.stack(CustomLayer), "GET", "https://google.com")
```

Ok, not terrible, but can we make it a little more convenient? We can. HTTP.jl provides a convenience macro that
will automatically define your own set of "user-facing request" methods, but with any specified custom layers
automatically included in the stack. Wait, this sounds magical; show me?

```
module MyClient

using HTTP

include("customlayer_definitions.jl")
HTTP.@client CustomLayer

end
```

Ok, so what we defined here is a module called `MyClient`, which included a custom layer implementation (not fully shown, just
`include`ed) and then the macro invocation of `HTTP.@client CustomerLayer`. The macro expands to define our very own
`MyClient.get`, `MyClient.post`, `MyClient.put`, `MyClient.delete`, etc. methods, but which each include `CustomLayer`
in the constructed request stack. Neat! So now users can just call:

```
using MyClient
resp = MyClient.get("https://google.com")
```

And they're using your customized http client request stack with the `CustomLayer` functionality! Cool!

"""
module Layers

export Layer, InitialLayer, RequestLayer, ConnectionLayer, ResponseLayer, BottomLayer

"""
    Layers.request(layer::L, args...)

HTTP.jl internal method for executing the stack of layers
that make up a client request. Layers form a linked list
and must explicitly pass control to the next layer to ensure
each layer has a chance to execute its part of the request.
Each layer overloads `Layers.request` for their specific layer
type and the `args` to overload depend on which layer "kind"
they subtype:
  * [`Layers.InitialLayer`](@ref): overloads `Layers.request(layer::TestLayer, ctx, method, url, headers, body)`; this is the top-most layer type
  * [`Layers.RequestLayer`](@ref): overloads `Layers.request(layer::TestLayer, ctx, request, body)`; the `method`, `url`, and `headers` of the `InitialLayer` have been bundled together into a single `request::Request` argument
  * [`Layers.ConnectionLayer`](@ref): overloads `Layers.request(layer::TestLayer, ctx, io, request, body)`; a connection has now been opened to the remote and is available in the `io` argument
  * [`Layers.ResponseLayer`](@ref): overloads `Layers.request(layer::TestLayer, ctx, resp)`; the request has been sent and a response has been received in the form of the `resp` argument

Note that _every_ `Layers.request` overloads has a `ctx::Dict{Symbol, Any}` argument available if
any state needs to be shared between layers during the life of the request.

See docs for the [`Layers`](@ref) module for a broader discussion on extending/customizing the client request stack.
"""
function request end

"""
    Layers.Layer

Abstract type that all client request layer "kinds" must subtype. These currently include:
  * [`Layers.InitialLayer`](@ref): top-most layers
  * [`Layers.RequestLayer`](@ref): initial `Request` object has been formed
  * [`Layers.ConnectionLayer`](@ref): a connection has been opened to the remote
  * [`Layers.ResponseLayer`](@ref): the `Request` has been written on the connection and a response received

Custom layers should subtype one of these layer "kinds" instead of subtyping `Layers.Layer` directly.
"""
abstract type Layer#{Next <: Layer}
    # next::Next
end


abstract type InitialLayer <: Layer end
abstract type RequestLayer <: Layer end
abstract type ConnectionLayer <: Layer end
abstract type ResponseLayer <: Layer end

# start the stack off w/ BottomLayer
struct BottomLayer <: ResponseLayer end

# bottom layer just returns the response
request(::BottomLayer, ctx, resp) = resp

end
