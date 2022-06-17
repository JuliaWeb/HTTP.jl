# API Reference

```@contents
Pages = ["reference.md"]
Depth = 3
```

## Client Requests

```@docs
HTTP.request
HTTP.get
HTTP.put
HTTP.post
HTTP.head
HTTP.patch
HTTP.delete
HTTP.open
HTTP.download
```

### Request/Response Objects

```@docs
HTTP.Request
HTTP.Response
HTTP.Stream
HTTP.WebSocket
HTTP.Messages.header
HTTP.Messages.headers
HTTP.Messages.hasheader
HTTP.Messages.headercontains
HTTP.Messages.setheader
HTTP.Messages.appendheader
HTTP.Messages.decode
```

### Request body types

```@docs
HTTP.Form
HTTP.Multipart
```

### Request exceptions

Request functions may throw the following exceptions:

```@docs
HTTP.ConnectError
HTTP.TimeoutError
HTTP.StatusError
HTTP.RequestError
```

### URIs

HTTP.jl uses the [URIs.jl](https://github.com/JuliaWeb/URIs.jl) package for handling
URIs. Some functionality from URIs.jl, relevant to HTTP.jl, are listed below:

```@docs
URI
URIs.escapeuri
URIs.unescapeuri
URIs.splitpath
Base.isvalid(::URIs.URI)
```

### Cookies

```@docs
HTTP.Cookie
HTTP.Cookies.stringify
HTTP.Cookies.addcookie!
HTTP.Cookies.cookies
```

### WebSockets

```@docs
HTTP.WebSockets.send
HTTP.WebSockets.receive
HTTP.WebSockets.close
HTTP.WebSockets.ping
HTTP.WebSockets.pong
HTTP.WebSockets.iterate(::WebSocket, st)
HTTP.WebSockets.isclosed
HTTP.WebSockets.isok
```

## Utilities

```@docs
HTTP.parse(::Type{HTTP.Request}, str)
HTTP.sniff
HTTP.Strings.escapehtml
HTTP.Strings.tocameldash
HTTP.Strings.iso8859_1_to_utf8
HTTP.Strings.ascii_lc_isequal
HTTP.statustext
```

## Server / Handlers

### Core Server

```@docs
HTTP.listen
HTTP.serve
WebSockets.listen
```

### Middleware / Handlers

```@docs
HTTP.Handler
HTTP.Middleware
HTTP.streamhandler
HTTP.Router
HTTP.register!
HTTP.getparams
HTTP.Handlers.cookie_middleware
HTTP.getcookies
HTTP.@logfmt_str
```

## Advanced Topics

### Messages Interface

```@docs
HTTP.Messages.iserror
HTTP.Messages.isredirect
HTTP.Messages.ischunked
HTTP.Messages.issafe
HTTP.Messages.isidempotent
HTTP.Messages.retryable
HTTP.Messages.defaultheader!
HTTP.Messages.readheaders
HTTP.DefaultHeadersRequest.setuseragent!
HTTP.Messages.readchunksize
HTTP.Messages.headerscomplete(::HTTP.Messages.Response)
HTTP.Messages.writestartline
HTTP.Messages.writeheaders
Base.write(::IO,::HTTP.Messages.Message)
HTTP.Streams.closebody
HTTP.Streams.isaborted
```

### Cookie Persistence

```@docs
HTTP.Cookies.CookieJar
HTTP.Cookies.getcookies!
HTTP.Cookies.setcookies!
```

### Client-side Middleware (Layers)

```@docs
HTTP.Layer
HTTP.@client
HTTP.pushlayer!
HTTP.pushfirstlayer!
HTTP.poplayer!
HTTP.popfirstlayer!
HTTP.MessageRequest.messagelayer
HTTP.RedirectRequest.redirectlayer
HTTP.DefaultHeadersRequest.defaultheaderslayer
HTTP.BasicAuthRequest.basicauthlayer
HTTP.CookieRequest.cookielayer
HTTP.CanonicalizeRequest.canonicalizelayer
HTTP.TimeoutRequest.timeoutlayer
HTTP.ExceptionRequest.exceptionlayer
HTTP.RetryRequest.retrylayer
HTTP.ConnectionRequest.connectionlayer
HTTP.DebugRequest.debuglayer
HTTP.StreamRequest.streamlayer
HTTP.ContentTypeDetection.contenttypedetectionlayer
```

### Raw Request Connection

```@docs
HTTP.openraw
HTTP.Connection
```

### Parser Interface

```@docs
HTTP.Parsers.find_end_of_header
HTTP.Parsers.find_end_of_chunk_size
HTTP.Parsers.find_end_of_trailer
HTTP.Parsers.parse_status_line!
HTTP.Parsers.parse_request_line!
HTTP.Parsers.parse_header_field
HTTP.Parsers.parse_chunk_size
```