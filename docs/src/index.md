# HTTP.jl Documentation

`HTTP.jl` provides a pure Julia library for HTTP functionality.

```@contents
```

## Requests
Note that the HTTP methods of POST, DELETE, PUT, etc. all follow the same format as `HTTP.get`, documented below.
```@docs
HTTP.get
HTTP.request
HTTP.Client
HTTP.Connection
```

## Server / Handlers
```@docs
HTTP.serve
HTTP.Server
HTTP.Handler
HTTP.HandlerFunction
HTTP.Router
HTTP.register!
HTTP.FourOhFour
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
