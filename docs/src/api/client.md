```@meta
CurrentModule = HTTP
```

# Client API

```@contents
Pages = ["api/client.md"]
Depth = 2
```

## Client Types and Operations

```@docs
HTTP.Transport
HTTP.Client
HTTP.RetryBucket
HTTP.RequestRetryError
HTTP.retry_attempts
HTTP.isrecoverable
HTTP.roundtrip!
HTTP.request
HTTP.get
HTTP.head
HTTP.query
HTTP.post
HTTP.put
HTTP.patch
HTTP.delete
HTTP.options
HTTP.open
HTTP.do!
HTTP.get!
HTTP.@client
HTTP.close_idle_connections!
HTTP.idle_connection_count
HTTP.isaborted
```

## Request Trace Events

```@docs
HTTP.RequestEvent
HTTP.ResponseHeadEvent
HTTP.RetryEvent
HTTP.RedirectEvent
HTTP.DoneEvent
```
