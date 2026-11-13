# HTTP.jl Documentation

`HTTP.jl` is a Julia library for HTTP Messages.

[`HTTP.request`](@ref) sends a HTTP Request Message and
returns a Response Message.

```julia
r = HTTP.request("GET", "http://httpbin.org/ip")
println(r.status)
println(String(r.body))
```

[`HTTP.open`](@ref) sends a HTTP Request Message and
opens an `IO` stream from which the Response can be read.

```julia
HTTP.open("GET", "https://tinyurl.com/bach-cello-suite-1-ogg") do http
    open(`vlc -q --play-and-exit --intf dummy -`, "w") do vlc
        write(vlc, http)
    end
end
```


```@contents
```

## Requests


```@docs
HTTP.request(::String,::HTTP.URIs.URI,::Array{Pair{String,String},1},::Any)
HTTP.open
HTTP.get
HTTP.put
HTTP.post
HTTP.head
```

Request functions may throw the following exceptions:

```@docs
HTTP.StatusError
HTTP.ParsingError
HTTP.IOError
```
```
Base.DNSError
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


## URIs

```@docs
HTTP.URI
HTTP.URIs.escapeuri
HTTP.URIs.unescapeuri
HTTP.URIs.splitpath
Base.isvalid(::HTTP.URIs.URI)
```


## Cookies

```@docs
HTTP.Cookie
```


## Utilities

```@docs
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
HTTP.Parsers.Parser
```


## Messages
*Source: `Messages.jl`*

```@docs
HTTP.Messages
```


## Streams
*Source: `Streams.jl`*

```@docs
HTTP.Streams.Stream
```


## Connections

*Source: `ConnectionPool.jl`*

```@docs
HTTP.ConnectionPool
```


# Internal Interfaces

## Parser Interface

```@docs
HTTP.Parsers.Message
HTTP.Parsers.Parser()
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

## IOExtras Interface

```@docs
HTTP.IOExtras
HTTP.IOExtras.unread!
HTTP.IOExtras.startwrite(::IO)
HTTP.IOExtras.isioerror
```


## Streams Interface

```@docs
HTTP.Streams.closebody
HTTP.Streams.isaborted
```


## Connection Pooling Interface

```@docs
HTTP.ConnectionPool.Connection
HTTP.ConnectionPool.Transaction
HTTP.ConnectionPool.pool
HTTP.ConnectionPool.getconnection
HTTP.IOExtras.unread!(::HTTP.ConnectionPool.Transaction,::SubArray{UInt8,1,Array{UInt8,1},Tuple{UnitRange{Int64}},true})
HTTP.IOExtras.startwrite(::HTTP.ConnectionPool.Transaction)
HTTP.IOExtras.closewrite(::HTTP.ConnectionPool.Transaction)
HTTP.IOExtras.startread(::HTTP.ConnectionPool.Transaction)
HTTP.IOExtras.closeread(::HTTP.ConnectionPool.Transaction)
```
