# HTTP.jl Documentation

`HTTP.jl` provides a pure Julia library for HTTP functionality.

```@contents
```

## Requests
Note that the HTTP methods of POST, DELETE, PUT, etc. all follow the same format as `HTTP.get`, documented below.
```@docs
HTTP.get
HTTP.send!
HTTP.Client
HTTP.Connection
```

## HTTP Types
```@docs
HTTP.Request
HTTP.Response
HTTP.Cookie
HTTP.URI
HTTP.FIFOBuffer
```

## HTTP Utilities
```@docs
HTTP.parse
HTTP.escape
HTTP.unescape
HTTP.userinfo
HTTP.splitpath
HTTP.isvalid
HTTP.sniff
```
