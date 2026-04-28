```@meta
CurrentModule = HTTP
```

# Core API

```@contents
Pages = ["api/core.md"]
Depth = 2
```

## Core Messages and Errors

```@docs
HTTP.Request
HTTP.Response
HTTP.Headers
HTTP.RequestContext
HTTP.HTTPError
HTTP.ParseError
HTTP.ProtocolError
HTTP.CanceledError
HTTP.TimeoutError
HTTP.HTTPTimeoutError
HTTP.StatusError
HTTP.TooManyRedirectsError
```

## Header and Context Helpers

```@docs
HTTP.canonical_header_key
HTTP.header
HTTP.headers
HTTP.hasheader
HTTP.headercontains
HTTP.setheader
HTTP.defaultheader!
HTTP.appendheader
HTTP.removeheader
HTTP.mkheaders
HTTP.get_request_context
HTTP.set_deadline!
HTTP.cancel!
HTTP.canceled
HTTP.expired
```

## Body Types and Streamed Payloads

```@docs
HTTP.AbstractBody
HTTP.CallbackBody
HTTP.nobody
HTTP.body_read!
HTTP.body_close!
HTTP.body_closed
HTTP.read_request
HTTP.write_request!
HTTP.write_response!
HTTP.trailers
```

## Cookies, Forms, and Request Bodies

```@docs
HTTP.Cookie
HTTP.CookieJar
HTTP.cookies
HTTP.stringify
HTTP.getcookies!
HTTP.setcookies!
HTTP.addcookie!
HTTP.Form
HTTP.Multipart
HTTP.content_type
HTTP.parse_multipart_form
```

## Proxy Configuration

```@docs
HTTP.ProxyConfig
HTTP.ProxyURL
HTTP.ProxyFromEnvironment
HTTP.NoProxy
```
