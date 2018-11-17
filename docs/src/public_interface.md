# Public Interface

## Requests

```@docs
HTTP.request(::String,::HTTP.URIs.URI,::Array{Pair{SubString{String},SubString{String}},1},::Any)
HTTP.open
HTTP.get
HTTP.put
HTTP.post
HTTP.head
```

Request functions may throw the following exceptions:

```@docs
HTTP.StatusError
HTTP.ParseError
HTTP.IOError
```
```
Sockets.DNSError
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
