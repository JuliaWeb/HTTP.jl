# HTTP.jl Documentation

`HTTP.jl` a Julia library for HTTP Messages.

```@contents
```

## Requests


```@docs
HTTP.request(::String,::HTTP.URIs.URI,::Array{Pair{String,String},1},::Any)
HTTP.get
HTTP.put
HTTP.post
HTTP.head
```


## Requests
Note that the HTTP methods of POST, DELETE, PUT, etc. all follow the same format as `HTTP.get`, documented below.

```
@docs
HTTP.get
HTTP.Client
HTTP.Connection
```


### HTTP request errors

```
@docs
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
HTTP.Cookie
```


## HTTP Utilities

```@docs
HTTP.URIs.escapeuri
HTTP.URIs.unescapeuri
HTTP.URIs.splitpath
Base.isvalid(::HTTP.URIs.URI)
HTTP.sniff
HTTP.Strings.escapehtml
```

# HTTP.jl Internal Architecture

```@docs
HTTP.Layer
HTTP.stack
```


## Request Execution Layers

```@docs
HTTP.RedirectLayer
HTTP.BasicAuthLayer
HTTP.CookieLayer
HTTP.CanonicalizeLayer
HTTP.MessageLayer
HTTP.AWS4AuthLayer
HTTP.RetryLayer
HTTP.ExceptionLayer
HTTP.ConnectionPoolLayer
HTTP.TimeoutLayer
HTTP.StreamLayer
```

## Parser

*Source: `Parsers.jl`*

```@docs
HTTP.Parsers
```


## Messages
*Source: `Messages.jl`*

```@docs
HTTP.Messages
```


## Connections

### Basic Connections

*Source: `Connect.jl`*

```@docs
HTTP.Connect
```


### Pooled Connections

*Source: `ConnectionPool.jl`*

```@docs
HTTP.ConnectionPool
```


# Internal Interfaces

## Parser Interface

```@docs
HTTP.Parsers.Parser
HTTP.Parsers.parseheaders
HTTP.Parsers.parsebody
HTTP.Parsers.reset!
HTTP.Parsers.messagestarted
HTTP.Parsers.headerscomplete
HTTP.Parsers.bodycomplete
HTTP.Parsers.messagecomplete
HTTP.Parsers.messagehastrailing
HTTP.Parsers.waitingforeof
HTTP.Parsers.seteof
HTTP.Parsers.connectionclosed
HTTP.Parsers.setnobody
```

## Messages Interface

```@docs
HTTP.Messages.Request
HTTP.Messages.Response
HTTP.Messages.iserror
HTTP.Messages.isredirect
HTTP.Messages.ischunked
HTTP.Messages.issafe
HTTP.Messages.isidempotent
HTTP.Messages.header
HTTP.Messages.hasheader
HTTP.Messages.setheader
HTTP.Messages.defaultheader
HTTP.Messages.appendheader
HTTP.Messages.readheaders
HTTP.Messages.readstartline!
HTTP.Messages.headerscomplete(::HTTP.Messages.Response)
HTTP.Messages.readtrailers
HTTP.Messages.writestartline
HTTP.Messages.writeheaders
Base.write(::IO,::HTTP.Messages.Message)
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
HTTP.Connect.getconnection(::Type{HTTP.ConnectionPool.Transaction{T}},::AbstractString,::AbstractString) where T <: IO
HTTP.IOExtras.unread!(::HTTP.ConnectionPool.Transaction,::SubArray{UInt8,1,Array{UInt8,1},Tuple{UnitRange{Int64}},true})
HTTP.IOExtras.startwrite(::HTTP.ConnectionPool.Transaction)
HTTP.IOExtras.closewrite(::HTTP.ConnectionPool.Transaction)
HTTP.IOExtras.startread(::HTTP.ConnectionPool.Transaction)
HTTP.IOExtras.closeread(::HTTP.ConnectionPool.Transaction)
```
