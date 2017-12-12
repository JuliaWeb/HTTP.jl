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

Source: [`Parsers.jl`](https://github.com/JuliaWeb/HTTP.jl/blob/master/src/Parsers.jl)

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

Source: [`Messages.jl`](https://github.com/JuliaWeb/HTTP.jl/blob/master/src/Messages.jl)

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
`Request`. The `Request` struct as a `parent` field that points to a `Response`
in the case of HTTP Redirect. The [`HTTP.Messages.parentcount`](@ref) function is
used to place a limit on nested redirects.


### Headers

Headers are represented by `Vector{Pair{String,String}}`. As compared to
`Dict{String,String}` this allows repeated header fields and preservation of
order.

Header values can be accessed by name using 
[`HTTP.Messages.header`](@ref) and
[`HTTP.Messages.setheader`](@ref).

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

Source: [`Connect.jl`](https://github.com/JuliaWeb/HTTP.jl/blob/master/src/Connect.jl)

[`HTTP.Connect.getconnection`](@ref) creates a new `TCPSocket` or `SSLContext`
for a specified `host` and `port.

No connection streaming, pooling or reuse is implemented in this module.
However, the `getconnection` interface is the same as the one used by the
connection pool so the `Connect` module can be used directly when reuse is
not required.


### Pooled Connections

Source: [`Connections.jl`](https://github.com/JuliaWeb/HTTP.jl/blob/master/src/Connections.jl)

This module wrapps the Basic Connections module above and adds support for:
- Reusing connections for multiple Request/Response Messages,
- Interleaving Request/Response Messages. i.e. allowing a new Request to be
  sent before while the previous Response is being read.

This module defines a [`HTTP.Connections.Connection`](@ref)` <: IO`
struct to manage Message streaming and connection reuse. Methods
are provided for `eof`, `readavailable`, `unsafe_write` and `close`.
This allows the `Connection` object to act as a proxy for the
`TCPSocket` or `SSLContext` that it wraps.


The [`HTTP.Connections.pool`](@ref) is a collection of open
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

## Request Execution

There are three seperate Request Execution layers, all with the same interface.
Clients can choose which layer to import according to the features they require.

### Basic Request Execution

Source: [`SendRequest.jl`](https://github.com/JuliaWeb/HTTP.jl/blob/master/src/SendRequest.jl)

The `SendRequest` module implements basic HTTP Request execution.

The `request` function is split into three methods:
- [`HTTP.SendRequest.request(method::String, uri, headers, body)`](@ref))
- [`HTTP.SendRequest.request(::HTTP.URIs.URI,request,response)`](@ref)
- [`HTTP.SendRequest.request(::IO, request, response)`](@ref)).

These methods implement:
- Creating a [`HTTP.Messages.Request`](@ref) for a specified method, URI,
  headers and body,
- Setting the mandatory `Host` and `Content-Length` (or `Transfer-Encoding`)
  headers.
- Getting a connection from the pool for a specified URI.
- Writing a `Request` to the connection and reading a `Response`.
- Raising a `StatusError` of the Response Status is not in the `2xx` range.

If the `Body` of the `Request` is connected to an `IO` stream, the `request`
function waits for the Response Headers to be recieved and schedules reading of
the the Response Body to happen as a background task.


### Request Execution With Retry

Source: [`RetryRequest.jl`](https://github.com/JuliaWeb/HTTP.jl/blob/master/src/RetryRequest.jl)

The `RetryRequest` module implements a `request` function that accepts the
same arguments as, and wraps,
[`HTTP.SendRequest.request(method::String, uri, headers, body)`](@ref)).

This layer adds a retry loop that repeats the `request` in the event of a
recoverable network error. A randomised exponentially increasing delay is
introduced between attempts to avoid making network congestion  worse.

Methods of `isrecoverable(e)` define which exception types lead to a retry:
`Base.UVError`, `Base.DNSError`, `Base.EOFError` and `HTTP.StatusError`
(if status is `1xx` or `5xx`).

### Request Execution With State

Source: [`CookieRequest.jl`](https://github.com/JuliaWeb/HTTP.jl/blob/master/src/CookieRequest.jl)

The `CookieRequest` module implements a `request` function that accepts the
same arguments as, and wraps the `RetryRequest.request` function.

This layer adds processing of client-side cookies, basic authorization headers
and `3xx` redirects.


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
Base.write(::IO,::Union{HTTP.Messages.Request, HTTP.Messages.Response})
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
HTTP.Messages.parentcount
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
HTTP.Connections.Connection
HTTP.Connections.pool
HTTP.Connect.getconnection(::Type{HTTP.Connections.Connection{T}},::AbstractString,::AbstractString) where T <: IO
HTTP.IOExtras.unread!(::HTTP.Connections.Connection,::SubArray{UInt8, 1})
HTTP.IOExtras.closewrite(::HTTP.Connections.Connection)
HTTP.IOExtras.closeread(::HTTP.Connections.Connection)
```


## Low Level Request Interface

```@docs
HTTP.SendRequest.request(::String,::Any,::Any,::Any)
HTTP.SendRequest.request(::HTTP.URIs.URI,::HTTP.Messages.Request,::HTTP.Messages.Response)
HTTP.SendRequest.request(::IO,::HTTP.Messages.Request,::HTTP.Messages.Response)
```
