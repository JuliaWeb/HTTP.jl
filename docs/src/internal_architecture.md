# Internal Architecture

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
