# HTTP.jl Documentation

`HTTP.jl` provides a pure Julia library for HTTP functionality.

```@contents
```

## Requests
Note that the HTTP methods of POST, DELETE, PUT, etc. all follow the same format as `HTTP.get`, documented below.
```@docs
HTTP.get
HTTP.Client
HTTP.Connection
```

### HTTP request errors
```@docs
HTTP.ConnectError
HTTP.SendError
HTTP.ClosedError
HTTP.ReadError
HTTP.RedirectError
HTTP.StatusError
```

## Server / Handlers
```@docs
HTTP.serve
HTTP.Server
HTTP.Handler
HTTP.HandlerFunction
HTTP.Router
HTTP.register!
```

## HTTP Types
```@docs
HTTP.URI
HTTP.Request
HTTP.RequestOptions
HTTP.Response
HTTP.Cookie
HTTP.FIFOBuffer
```

## HTTP Utilities
```@docs
HTTP.parse
HTTP.escape
HTTP.unescape
HTTP.splitpath
HTTP.isvalid
HTTP.sniff
HTTP.escapeHTML
```

# HTTP.jl Architecture

## Parser

Source: `Parsers.jl`

The [`HTTP.Parser`](@ref) separates HTTP Message data (from a `String`,
an `IO` stream or raw bytes) into its component parts. The parts are passed to
three callback functions as they are parsed:
- `onheader(::Pair{String,String})`
- `onheaderscomplete(::`[`HTTP.Parsers.Message`](@ref)`)`
- `onbodyfragment(::SubArray{UInt8,1})`

If the input data is invalid the Parser throws a [`HTTP.ParsingError`](@ref).

A Parser processes a single HTTP Message. If the input stream contains
multiple Messages the Parser stops at the end of the first Message.
The `parse!(::Parser, data)` function returns the number of bytes consumed.
If less than `length(data)` was consumed, the excess must be processed
separately. The `read!(io, ::Parser)` method deals with this by pushing
the excess bytes back into the stream using `IOExtras.unread!`.

The Parser does not interpret the Message Headers except as is necessary
to parse the Message Body. It is beyond the scope of the Parser to deal
with repeated header fields, multi-line values, cookies or case normalization
(see [`HTTP.Messages.appendheader`](@ref)).

The Parser has no knowledge of the high-level `Request` and `Response` structs
defined in `Messages.jl`. The Parser has it's own low level
[`HTTP.Parsers.Message`](@ref) struct that represents both Request and Response
Messages.


## Messages

Source: `Messages.jl`

The `Messages` module defines structs that represent [`HTTP.Messages.Request`](@ref)
and [`HTTP.Messages.Response`](@ref) Messages.

The Messages module defines `IO` `read` and `write` methods for Messages
but it does not deal with URIs, creating connections, or executing requests.

The Messages module does not explicitly throw exceptions, but it calls
methods that may result in low level `IO` exceptions.

### Sending Messages

Messages are formatted and written to an `IO` stream by
[`Base.write(::IO,::HTTP.Messages.Message)`](@ref).

[`Base.write(::IO, ::HTTP.Messages.Bodies.Body)`](@ref) is called to output the
Message Body. This function implements `chunked` encoding if the body length
is unknown.


### Receiving Messages

Messages are parsed from `IO` stream data by
[`Base.read!(::IO,::HTTP.Messages.Message)`](@ref).

This function creates a [`HTTP.Parser`](@ref) with callbacks as follows
- `onheader` = [`HTTP.Messages.appendheader`](@ref)
- `onheaderscomplete` = [`HTTP.Messages.readstartline!`](@ref)
- `onbodyfragment` = [`Base.write(::HTTP.Messages.Bodies.Body, bytes)`](@ref)

[`Base.read!(::IO, ::HTTP.Parser)`](@ref) is called to feed the Parser
with data from the `IO` stream. As the Parser processes the data the
callbacks are called to fill in the `Message` struct.

The `Response` struct has a `parent` field that points to the corresponding
`Request`. The `Request` struct has a `parent` field that points to a `Response`
in the case of HTTP Redirect.


### Headers

Headers are represented by `Vector{Pair{String,String}}`. As compared to
`Dict{String,String}` this allows repeated header fields and preservation of
order.

Header values can be accessed by name using 
[`HTTP.Messages.header`](@ref) and
[`HTTP.Messages.setheader`](@ref) (case-insensitive).

The [`HTTP.Messages.appendheader`](@ref) function handles combining
multi-line values, repeated header fields and special handling of
multiple `Set-Cookie` headers.

### Bodies

The [`HTTP.Messages.Bodies.Body`](@ref) struct represents a Message Body.
It either stores static body data in an `IOBuffer`, or wraps an `IO` stream
that will consume or produce the Message Body.

The [`HTTP.Messages.setlengthheader`](@ref) function sets the `Content-Length`
header if the Message Body has known length, or sets the
`Transfer-Encoding: chunked` header to indicate that the Body length is not
known at the time the headers are sent.


## Connections

### Basic Connections

Source: `Connect.jl`

[`HTTP.Connect.getconnection`](@ref) creates a new `TCPSocket` or `SSLContext`
for a specified `host` and `port`.

No connection streaming, pooling or reuse is implemented in this module.
However, the `getconnection` interface is the same as the one used by the
connection pool so the `Connect` module can be used directly when reuse is
not required.


### Pooled Connections

Source: `ConnectionPool.jl`

This module wrapps the Basic Connect module above and adds support for:
- Reusing connections for multiple Request/Response Messages,
- Interleaving Request/Response Messages. i.e. allowing a new Request to be
  sent before while the previous Response is being read.

This module defines a [`HTTP.ConnectionPool.Connection`](@ref)` <: IO`
struct to manage Message streaming and connection reuse. Methods
are provided for `eof`, `readavailable`, `unsafe_write` and `close`.
This allows the `Connection` object to act as a proxy for the
`TCPSocket` or `SSLContext` that it wraps.


The [`HTTP.ConnectionPool.pool`](@ref) is a collection of open
`Connection`s.  The `request` function calls `getconnection` to
retrieve a connection from the `pool`.  When the `request` function
has written a Request Message it calls `closewrite` to signal that
the `Connection` can be reused for writing (to send the next Request).
When the `request` function has read the Response Message it calls
`closeread` to signal that the `Connection` can be reused for
reading.

e.g.
```julia
request(uri::URI, req::Request, res::Response)
    T = uri.scheme == "https" ? SSLContext : TCPSocket
    io = getconnection(Connection{T}, uri.host, uri.port)
    write(io, req)
    closewrite(io)
    read!(io, res)
    closeread(io)
    return res
end
```

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

request(::Type{Layer1{Next}}, data) where Next = "L1", request(Next, data)
request(::Type{Layer2{Next}}, data) where Next = "L2", request(Next, data)
request(::Type{Layer3}, data) = "L3", data

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
combined but still allows Julia to do whole-stack comiple time optimistations.

e.g. the `request(stack1, "foo")` call above is optimised down to a single
function:
```julia
julia> code_typed(request, (Type{stack1}, String))[1].first
CodeInfo(:(begin
    return (Core.tuple)("L1", (Core.tuple)("L2", (Core.tuple)("L3", data)))
end))
```

In `HTTP.jl` the `const DefaultStack` type defines the default HTTP Request
processing stack. This is used as the default first parameter of the `request`
function.

```julia
const DefaultStack =
    RedirectLayer{
    CanonicalizeLayer{
    BasicAuthLayer{
    CookieLayer{
    RetryLayer{
    ExceptionLayer{
    MessageLayer{
    ConnectionLayer{ConnectionPool.Connection,
    SocketLayer
    }}}}}}}}

request(method::String, uri, headers=[], body=""; kw...) =
    request(HTTP.DefaultStack, method, uri, headers, body; kw...)
```

Note that the `ConnectLayer`'s optional first parameter is a connection wrapper
type.  If it was omitted then `ConnectionLayer` would use raw socket types from
the `Connect` module directly.


## Redirect Layer

Source: `RedirectRequest.jl`

This layer adds a loop to process `3xx` redirects.


## Canonicalize Layer

Source: `CanonicalizeRequest.jl`

This layer rewrites header field names to canonical Camel-Dash form.


## Basic Authentication Layer

Source: `BasicAuthRequest.jl`

This layer adds an `Authorization: Basic` header using `URI.userinfo`.


## Cookie Layer

Source: `CookieRequest.jl`

This layer stores cookies sent by the server and sends them back to the
server with subsequent requests.


## Retry Layer

Source: `RetryRequest.jl`

The `RetryRequest` module implements a `request` method with a retry loop that
repeats the request in the event of a recoverable network error.
A randomised exponentially increasing delay is introduced between attempts to
avoid exacerbating network congestion.

Methods of `isrecoverable(e)` define which exception types lead to a retry.
e.g. `Base.UVError`, `Base.DNSError`, `Base.EOFError` and `HTTP.StatusError`
(if status is `1xx` or `5xx`).


## ExceptionLayer

Source: `ExceptionRequest.jl`

This layer throws a `StatusError` if the Response Status indicates an error.


## Message Layer

Source: `MessageRequest.jl`

This layer:
- Creates a [`HTTP.Messages.Request`](@ref) object for the specified
  method, URI, headers and body,
- Sets the mandatory `Host` and `Content-Length` (or `Transfer-Encoding`)
  headers.
- Creates a [`HTTP.Messages.Response`](@ref) object to hold the response. 


## Connection Layer

Source: `ConnectionRequest.jl`

This layer calls [`HTTP.Connect.getconnection`](@ref)
to get a socket from connection pool.


## Socket Layer

Source: `SocketRequest.jl`

This layer calls [`HTTP.Messages.writeandread`](@ref) to send the Request
to the socket and receive the Response.

If the `Body` of the `Request` is connected to an `IO` stream, the `request`
function waits for the Response Headers to be received, but schedules reading of
the Response Body to happen in a background task.


# Internal Interfaces

## Parser Interface

```@docs
HTTP.Parser
HTTP.Parsers.Message
HTTP.Parsers.parse!
Base.read!(::IO, ::HTTP.Parser)
HTTP.Parsers.messagecomplete
HTTP.Parsers.headerscomplete
HTTP.Parsers.waitingforeof
```

## Messages Interface

### Message

`const Message = Union{Request,Response}`

```@docs
HTTP.Messages.header
HTTP.Messages.setheader
HTTP.Messages.defaultheader
HTTP.Messages.setlengthheader
HTTP.Messages.appendheader
HTTP.Messages.waitforheaders
Base.wait(::HTTP.Messages.Response)
Base.write(::IO,::Union{HTTP.Messages.Request, HTTP.Messages.Response})
HTTP.Messages.writeandread
HTTP.Messages.readstartline!
```

### Request

```@docs
HTTP.Messages.Request
```

### Response

```@docs
HTTP.Messages.Response
HTTP.Messages.iserror
HTTP.Messages.isredirect
HTTP.Messages.method
```

### Body

```@docs
HTTP.Messages.Bodies.Body
HTTP.Messages.Bodies.isstream
Base.write(::HTTP.Messages.Bodies.Body, ::Any)
Base.write(::IO, ::HTTP.Messages.Bodies.Body)
Base.length(::HTTP.Messages.Bodies.Body)
Base.take!(::HTTP.Messages.Bodies.Body)
HTTP.Messages.Bodies.set_show_max
HTTP.Messages.Bodies.collect!
```


## Connections Interface

### Low Level Connect Interface

```@docs
HTTP.Connect.getconnection(::Type{TCPSocket},::AbstractString,::AbstractString)
```

### Connection Pooling Interface

```@docs
HTTP.ConnectionPool.Connection
HTTP.ConnectionPool.pool
HTTP.Connect.getconnection(::Type{HTTP.ConnectionPool.Connection{T}},::AbstractString,::AbstractString) where T <: IO
HTTP.IOExtras.unread!(::HTTP.ConnectionPool.Connection,::SubArray{UInt8, 1})
HTTP.IOExtras.closewrite(::HTTP.ConnectionPool.Connection)
HTTP.IOExtras.closeread(::HTTP.ConnectionPool.Connection)
```


## Low Level Request Interface

```@docs
HTTP.RequestStack.request
```
