# Public Interface

## Requests

```@docs
HTTP.request
HTTP.open
HTTP.get
HTTP.put
HTTP.post
HTTP.head
```

### Request body types

```@docs
HTTP.Form
HTTP.Multipart
```

### Request exceptions

Request functions may throw the following exceptions:

```@docs
HTTP.StatusError
HTTP.ParseError
HTTP.IOError
```
```@docs
Sockets.DNSError
```

## URIs

HTTP.jl uses the [URIs.jl](https://github.com/JuliaWeb/URIs.jl) package for handling
URIs. Some functionality from URIs.jl, relevant to HTTP.jl, are listed below:

```@docs
URI
URIs.escapeuri
URIs.unescapeuri
URIs.splitpath
Base.isvalid(::URIs.URI)
```


## Cookies

```@docs
HTTP.Cookie
```


## Utilities

```@docs
HTTP.sniff
HTTP.Strings.escapehtml
HTTP.statustext
```

## Server / Handlers

```@docs
HTTP.listen
HTTP.serve
HTTP.Handlers
HTTP.handle
HTTP.RequestHandlerFunction
HTTP.StreamHandlerFunction
HTTP.Router
HTTP.@register
```

## Messages Interface

```@docs
HTTP.Request
HTTP.Response
HTTP.status
HTTP.headers
HTTP.body
HTTP.method
HTTP.uri
```

