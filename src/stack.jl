import Base.length

"""
## Request Execution Stack

The Request Execution Stack is separated into composable layers.

Each layer is defined by a nested type `Layer{Next}` where the `Next`
parameter defines the next layer in the stack.
The `request` method for each layer takes a `Layer{Next}` type as
its first argument and dispatches the request to the next layer
using `request(Next, ...)`.

The example below defines three layers and three stacks each with
a different combination of layers.

```julia
abstract type Layer end
abstract type Layer1{Next <: Layer} <: Layer end
abstract type Layer2{Next <: Layer} <: Layer end
abstract type Layer3 <: Layer end

const stack1 = Layer1{Layer2{Layer3}}
const stack2 = Layer2{Layer1{Layer3}}
const stack3 = Layer1{Layer3}
```

```julia
julia> request(stack1, "foo")
("L1", ("L2", ("L3", "foo")))

julia> request(stack2, "bar")
("L2", ("L1", ("L3", "bar")))

julia> request(stack3, "boo")
("L1", ("L3", "boo"))
```

This stack definition pattern gives the user flexibility in how layers are
combined but still allows Julia to do whole-stack compile time optimisations.

e.g. the `request(stack1, "foo")` call above is optimised down to a single
function:
```julia
julia> code_typed(request, (Type{stack1}, String))[1].first
CodeInfo(:(begin
    return (Core.tuple)("L1", (Core.tuple)("L2", (Core.tuple)("L3", data)))
end))
```
"""
abstract type Layer end

"""
    EXTRA_LAYERS

Extra layers to be added to the stack.
Add or remove extra layers from this const via `insert_default!` and `remove_default!`.
"""
const EXTRA_LAYERS = Set{Tuple{Type,Type}}()

"""
    Stack{L<:Layer}

Struct containing the layer `L` to dispatch on with `request` and the next element to
dispatch on `next`.
This type allows for dispatching on `L` inside `request`.
These stacks are created by `HTTP.stack`.

Regarding performance, runtime dispatch could be avoided by defining a `Stack{U,V}` so that
request methods can specialize further.
However, this is unlikely to be much quicker when looking at the large `request` method
bodies.

# Examples
```
julia> s1 = Stack{RetryLayer}(Stack{BasicAuthLayer}(nothing))

julia> s2 = Stack{RetryLayer}(nothing)
```
"""
struct Stack{T<:Layer}
    next::Union{Stack,Nothing}
end

"""
    layers2stack(layers::Vector)

Create a stack from `layers`.

# Example
```
julia> HTTP.layers2stack([BasicAuthLayer, RetryLayer])
Stack{BasicAuthLayer}(Stack{RetryLayer}(nothing))
```
"""
function layers2stack(layers)
    length(layers) == 0 && error("Expecting at least one layer to create a stack")
    last = Stack{layers[end]}(nothing)
    length(layers) == 1 && return last

    stack = last
    for layer in reverse(layers[1:end-1])
        stack = Stack{layer}(stack)
    end
    return stack
end

stacktype(stack::Stack{T}) where {T} = T
length(stack::Stack) = length(stack2layers(stack))

"""
    insert_before!(a::Vector, before, item)

Insert an `item` into `a` in front of the first element that is equal to `before`.
"""
function insert_before!(a::Vector, before, item)
    i = findfirst(x -> x == before, a)
    return insert!(a, i, item)
end

function insert(stack::Stack, index::Int, custom_layer::Type{<:Layer})
    layers = stack2layers(stack)
    layers = insert!(layers, index, custom_layer)
    return layers2stack(layers)
end

"""
    insert(stack::Stack, layer_before::Type{<:Layer}, custom_layer::Type{<:Layer})

Insert your `custom_layer` in-front of the `layer_before`.

# Example
```
julia> stack = HTTP.layers2stack([MessageLayer, ConnectionPoolLayer])
Stack{MessageLayer}(Stack{ConnectionPoolLayer}(nothing))

julia> insert(stack, HTTP.MessageLayer, HTTP.RetryLayer)
Stack{RetryLayer}(Stack{MessageLayer}(Stack{ConnectionPoolLayer}(nothing)))
```
"""
function insert(stack::Stack, layer_before::Type{<:Layer}, custom_layer::Type{<:Layer})
    layers = stack2layers(stack)
    if layer_before in layers
        layers = insert_before!(layers, layer_before, custom_layer)
        return layers2stack(layers)
    else
        throw(LayerNotFoundException("$layer_before not found in $stack"))
    end
end


"""
    stack2layers(stack::Stack)

Return the layers contained in the stack.

# Example
```
julia> HTTP.stack2layers(Stack{BasicAuthLayer}(Stack{RetryLayer}(nothing)))
[BasicAuthLayer, RetryLayer]
```
"""
function stack2layers(stack::Stack)
    stack.next === nothing && return [stacktype(stack)]
    layers = Type{<:Layer}[]
    element = stack
    while true
        push!(layers, stacktype(element))
        element = element.next
        element === nothing && break
    end
    return layers
end

"""
The `stack()` function returns the default HTTP Layer-stack type.
This type is passed as the first parameter to the [`HTTP.request`](@ref) function.

`stack()` accepts optional keyword arguments to enable/disable specific layers
in the stack:
`request(method, args...; kw...) request(stack(; kw...), args...; kw...)`


The minimal request execution stack is:

```julia
stack = MessageLayer{ConnectionPoolLayer{StreamLayer}}
```

The figure below illustrates the full request execution stack and its
relationship with [`HTTP.Response`](@ref), [`HTTP.Parsers`](@ref),
[`HTTP.Stream`](@ref) and the [`HTTP.ConnectionPool`](@ref).

```
 ┌────────────────────────────────────────────────────────────────────────────┐
 │                                            ┌───────────────────┐           │
 │  HTTP.jl Request Execution Stack           │ HTTP.ParsingError ├ ─ ─ ─ ─ ┐ │
 │                                            └───────────────────┘           │
 │                                            ┌───────────────────┐         │ │
 │                                            │ HTTP.IOError      ├ ─ ─ ─     │
 │                                            └───────────────────┘      │  │ │
 │                                            ┌───────────────────┐           │
 │                                            │ HTTP.StatusError  │─ ─   │  │ │
 │                                            └───────────────────┘   │       │
 │                                            ┌───────────────────┐      │  │ │
 │     request(method, url, headers, body) -> │ HTTP.Response     │   │       │
 │             ──────────────────────────     └─────────▲─────────┘      │  │ │
 │                           ║                          ║             │       │
 │   ┌────────────────────────────────────────────────────────────┐      │  │ │
 │   │ request(TopLayer,          method, ::URI, ::Headers, body) │   │       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
 │   │ request(BasicAuthLayer,    method, ::URI, ::Headers, body) │   │       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
 │   │ request(BasicAuthLayer,    method, ::URI, ::Headers, body) │   │       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
 │   │ request(CookieLayer,       method, ::URI, ::Headers, body) │   │       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
 │   │ request(CanonicalizeLayer, method, ::URI, ::Headers, body) │   │       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
 │   │ request(MessageLayer,      method, ::URI, ::Headers, body) │   │       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
 │   │ request(AWS4AuthLayer,             ::URI, ::Request, body) │   │       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
 │   │ request(RetryLayer,                ::URI, ::Request, body) │   │       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
 │   │ request(ExceptionLayer,            ::URI, ::Request, body) ├ ─ ┘       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
┌┼───┤ request(ConnectionPoolLayer,       ::URI, ::Request, body) ├ ─ ─ ─     │
││   ├────────────────────────────────────────────────────────────┤         │ │
││   │ request(DebugLayer,                ::IO,  ::Request, body) │           │
││   ├────────────────────────────────────────────────────────────┤         │ │
││   │ request(TimeoutLayer,              ::IO,  ::Request, body) │           │
││   ├────────────────────────────────────────────────────────────┤         │ │
││   │ request(StreamLayer,               ::IO,  ::Request, body) │           │
││   └──────────────┬───────────────────┬─────────────────────────┘         │ │
│└──────────────────┼────────║──────────┼───────────────║─────────────────────┘
│                   │        ║          │               ║                   │
│┌──────────────────▼───────────────┐   │  ┌──────────────────────────────────┐
││ HTTP.Request                     │   │  │ HTTP.Response                  │ │
││                                  │   │  │                                  │
││ method::String                   ◀───┼──▶ status::Int                    │ │
││ target::String                   │   │  │ headers::Vector{Pair}            │
││ headers::Vector{Pair}            │   │  │ body::Vector{UInt8}            │ │
││ body::Vector{UInt8}              │   │  │                                  │
│└──────────────────▲───────────────┘   │  └───────────────▲────────────────┼─┘
│┌──────────────────┴────────║──────────▼───────────────║──┴──────────────────┐
││ HTTP.Stream <:IO          ║           ╔══════╗       ║                   │ │
││   ┌───────────────────────────┐       ║   ┌──▼─────────────────────────┐   │
││   │ startwrite(::Stream)      │       ║   │ startread(::Stream)        │ │ │
││   │ write(::Stream, body)     │       ║   │ read(::Stream) -> body     │   │
││   │ ...                       │       ║   │ ...                        │ │ │
││   │ closewrite(::Stream)      │       ║   │ closeread(::Stream)        │   │
││   └───────────────────────────┘       ║   └────────────────────────────┘ │ │
│└───────────────────────────║────────┬──║──────║───────║──┬──────────────────┘
│┌──────────────────────────────────┐ │  ║ ┌────▼───────║──▼────────────────┴─┐
││ HTTP.Messages                    │ │  ║ │ HTTP.Parsers                     │
││                                  │ │  ║ │                                  │
││ writestartline(::IO, ::Request)  │ │  ║ │ parse_status_line(bytes, ::Req') │
││ writeheaders(::IO, ::Request)    │ │  ║ │ parse_header_field(bytes, ::Req')│
│└──────────────────────────────────┘ │  ║ └──────────────────────────────────┘
│                            ║        │  ║
│┌───────────────────────────║────────┼──║────────────────────────────────────┐
└▶ HTTP.ConnectionPool       ║        │  ║                                    │
 │                     ┌──────────────▼────────┐ ┌───────────────────────┐    │
 │ getconnection() ->  │ HTTP.Transaction <:IO │ │ HTTP.Transaction <:IO │    │
 │                     └───────────────────────┘ └───────────────────────┘    │
 │                           ║    ╲│╱    ║                  ╲│╱               │
 │                           ║     │     ║                   │                │
 │                     ┌───────────▼───────────┐ ┌───────────▼───────────┐    │
 │              pool: [│ HTTP.Connection       │,│ HTTP.Connection       │...]│
 │                     └───────────┬───────────┘ └───────────┬───────────┘    │
 │                           ║     │     ║                   │                │
 │                     ┌───────────▼───────────┐ ┌───────────▼───────────┐    │
 │                     │ Base.TCPSocket <:IO   │ │MbedTLS.SSLContext <:IO│    │
 │                     └───────────────────────┘ └───────────┬───────────┘    │
 │                           ║           ║                   │                │
 │                           ║           ║       ┌───────────▼───────────┐    │
 │                           ║           ║       │ Base.TCPSocket <:IO   │    │
 │                           ║           ║       └───────────────────────┘    │
 └───────────────────────────║───────────║────────────────────────────────────┘
                             ║           ║
 ┌───────────────────────────║───────────║──────────────┐  ┏━━━━━━━━━━━━━━━━━━┓
 │ HTTP Server               ▼                          │  ┃ data flow: ════▶ ┃
 │                        Request     Response          │  ┃ reference: ────▶ ┃
 └──────────────────────────────────────────────────────┘  ┗━━━━━━━━━━━━━━━━━━┛
```
*See `docs/src/layers`[`.monopic`](http://monodraw.helftone.com).*
"""
function stack(;redirect=true,
                aws_authorization=false,
                cookies=false,
                canonicalize_headers=false,
                retry=true,
                status_exception=true,
                readtimeout=0,
                detect_content_type=false,
                verbose=0,
                kw...)

    layers = Union{Type{<:HTTP.Layer},Missing}[
        redirect ? RedirectLayer : missing,
        BasicAuthLayer,
        detect_content_type ? ContentTypeDetectionLayer : missing,
        cookies === true || (cookies isa AbstractDict && !isempty(cookies)) ? CookieLayer : missing,
        canonicalize_headers ? CanonicalizeLayer : missing,
        MessageLayer,
        aws_authorization ? AWS4AuthLayer : missing,
        retry ? RetryLayer : missing,
        status_exception ? ExceptionLayer : missing,
        ConnectionPoolLayer,
        (verbose >= 3 || DEBUG_LEVEL[] >= 3) ? DebugLayer : missing,
        readtimeout > 0 ? TimeoutLayer : missing,
        StreamLayer
    ]
    layers = collect(skipmissing(layers))
    if length(EXTRA_LAYERS) == 0
        stack = layers2stack(layers)::Union{Stack{RedirectLayer},Stack{BasicAuthLayer}}
        return stack
    else
        for (before, custom_layer) in EXTRA_LAYERS
            insert_before!(layers, before, custom_layer)
        end
        return layers2stack(layers)
    end
end

insert_default!(before::Type{<:Layer}, custom_layer::Type{<:Layer}) =
    push!(EXTRA_LAYERS, (before, custom_layer))

remove_default!(before::Type{<:Layer}, custom_layer::Type{<:Layer}) =
    delete!(EXTRA_LAYERS, (before, custom_layer))
