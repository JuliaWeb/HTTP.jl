# Migrating from HTTP.jl v1.x to v2.0.0

This guide will help you update your code from HTTP.jl v1.x to the new HTTP.jl v2.0.0. The new version brings significant improvements in architecture, performance, and API design, but does involve some breaking changes that will require adjustments to existing code.

## Overview of Major Changes

HTTP.jl v2.0.0 introduces several significant changes:

1. **Foundation Change**: The package now uses AWS Common Runtime (CRT) libraries under the hood instead of the previous pure Julia implementation
2. **API Simplification**: Streamlined and more consistent API design
3. **WebSockets Reimplementation**: Completely rewritten WebSockets support with improved reliability
4. **Server Implementation**: Redesigned server functionality with better performance characteristics
5. **Error Handling**: More consistent error types and handling patterns

## Core Client Changes

### Request and Response Objects

The `HTTP.Request` and `HTTP.Response` objects have changed in v2.0:

#### Before (v1.x)
```julia
# Making a request
r = HTTP.request("GET", "http://example.com")

# Accessing fields
status = r.status
body_text = String(r.body)
header_value = HTTP.header(r, "Content-Type")
```

#### After (v2.0)
```julia
# Making a request
r = HTTP.request("GET", "http://example.com")

# Accessing fields
status = r.status
body_text = String(r.body)  # Similar to v1.x
header_value = HTTP.header(r.headers, "Content-Type")
```

Key differences:
- Headers access has changed slightly to operate on the `headers` field
- The `.body` field can now be any type, not just `Vector{UInt8}`
- Context dictionary access is now through `.context` rather than request-specific fields

### Making Requests

While the basic request syntax remains similar, there are some changes to keyword arguments and behavior:

#### Changes to Keyword Arguments

- The `response_stream` keyword argument is still supported, but HTTP.jl no longer automatically closes this stream when done - you need to handle this yourself
- `retry` behavior has been overhauled with more consistent rules for what is retryable
- Some connection-related options have new defaults (e.g., TLS is now OpenSSL-based by default rather than MbedTLS)

Example:
```julia
# Before (v1.x)
io = open("output.bin", "w")
HTTP.get("http://example.com/data.bin", response_stream=io)
# Stream was automatically closed

# After (v2.0)
io = open("output.bin", "w")
HTTP.get("http://example.com/data.bin", response_stream=io)
close(io) # Must explicitly close stream
```

### Streaming Requests with HTTP.open

The `HTTP.open` function still exists but has some behavioral changes:

```julia
# Before (v1.x)
HTTP.open("GET", "http://example.com") do http
    # Data was automatically streamed when reading
    while !eof(http)
        data = readavailable(http)
        # Process data
    end
end

# After (v2.0)
HTTP.open("GET", "http://example.com") do http
    # Start reading must be explicitly called
    startread(http)
    while !eof(http)
        data = readavailable(http)
        # Process data
    end
end
```

## Server Changes

The server API has been significantly redesigned in v2.0.0. The new implementation offers better performance and a more consistent API.

### Basic Server Usage

#### Before (v1.x)
```julia
# Blocking server
HTTP.listen(host, port) do http::HTTP.Stream
    # Process request
    HTTP.setstatus(http, 200)
    HTTP.setheader(http, "Content-Type" => "text/plain")
    HTTP.startwrite(http)
    write(http, "Hello world")
end

# Non-blocking server
server = HTTP.listen!(host, port) do http::HTTP.Stream
    # Process request
    # Same pattern as above
end
```

#### After (v2.0)
```julia
# Blocking server (similar syntax)
HTTP.serve(host, port) do req::HTTP.Request
    # Process request and return a response
    return HTTP.Response(200, "Hello world")
end

# Non-blocking server
server = HTTP.serve!(host, port) do req::HTTP.Request
    # Process request and return a response
    return HTTP.Response(200, "Hello world")
end
```

Key differences:
- Most server functionality has been standardized around `serve`/`serve!` rather than `listen`/`listen!`
- The handler typically works with `Request`/`Response` objects rather than `Stream` objects
- The lifecycle management for servers has improved with clearer semantics for `isopen`, `close`, and `wait`

### Stream-based Handlers

If you need to work with streams directly:

```julia
# Before (v1.x)
HTTP.listen(host, port) do http::HTTP.Stream
    while !eof(http)
        data = readavailable(http)
        # Process streaming data
    end
    HTTP.setstatus(http, 200)
    HTTP.startwrite(http)
    write(http, "Response")
end

# After (v2.0)
HTTP.serve(host, port; stream=true) do http::HTTP.Stream
    while !eof(http)
        data = readavailable(http)
        # Process streaming data
    end
    HTTP.setstatus(http, 200)
    HTTP.startwrite(http)
    write(http, "Response")
end
```

Note the addition of the `stream=true` keyword argument to indicate you want to work with a stream handler.

### Router and Middleware

The Handler and Middleware framework has been redesigned for more clarity and consistency:

#### Before (v1.x)
```julia
# Creating middleware
function logging_middleware(handler)
    return function(req)
        @info "Request received: $(req.method) $(req.target)"
        return handler(req)
    end
end

# Using a router
router = HTTP.Router()
HTTP.register!(router, "GET", "/api/data", handler_function)

# Using middleware with a router
HTTP.serve(logging_middleware(router), host, port)
```

#### After (v2.0)
```julia
# Creating middleware (similar concept, cleaner implementation)
function logging_middleware(handler)
    return function(req)
        @info "Request received: $(req.method) $(req.url.path)"
        return handler(req)
    end
end

# Using a router
router = HTTP.Router()
HTTP.register!(router, "GET", "/api/data", handler_function)

# Using middleware with a router
HTTP.serve(logging_middleware(router), host, port)
```

The core concepts remain similar, but the implementation is cleaner and more consistent.

## WebSockets Changes

WebSockets implementation has been completely rewritten in v2.0.0, building on AWS CRT libraries for better reliability and performance.

### Client WebSockets

#### Before (v1.x)
```julia
using HTTP.WebSockets

WebSockets.open("ws://example.com/socket") do ws
    send(ws, "Hello server")
    for msg in ws
        # Process received messages
        println("Received: $msg")
        # Optionally send a response
        send(ws, "Response to $msg")
    end
end
```

#### After (v2.0)
```julia
using HTTP.WebSockets

WebSockets.open("ws://example.com/socket") do ws
    send(ws, "Hello server")
    for msg in ws
        # Process received messages
        println("Received: $msg")
        # Optionally send a response
        send(ws, "Response to $msg")
    end
end
```

The basic client WebSocket API remains largely the same, though the underlying implementation has changed significantly.

### Server WebSockets

#### Before (v1.x)
```julia
using HTTP.WebSockets

# Non-blocking server
server = WebSockets.listen!("127.0.0.1", 8081) do ws
    for msg in ws
        # Echo back any received message
        send(ws, msg)
    end
end

# Later
close(server)
```

#### After (v2.0)
```julia
using HTTP.WebSockets

# Non-blocking server
server = WebSockets.serve!("127.0.0.1", 8081) do ws
    for msg in ws
        # Echo back any received message
        send(ws, msg)
    end
end

# Later
close(server)
```

Note the change from `listen!` to `serve!` to maintain consistency with the HTTP server API.

## Error Handling

Error types have been standardized for more consistency:

- `HTTP.ConnectError`: Connection establishment failures
- `HTTP.TimeoutError`: Request timeouts
- `HTTP.StatusError`: Responses with error status codes
- `HTTP.RequestError`: Generic request errors with an embedded cause

### Example of Error Handling

```julia
# Robust error handling in v2.0
try
    HTTP.get("https://example.com/resource")
catch e
    if e isa HTTP.ConnectError
        println("Connection failed: $(e.error)")
    elseif e isa HTTP.TimeoutError
        println("Request timed out after $(e.timeout) seconds")
    elseif e isa HTTP.StatusError
        println("Server returned error status: $(e.status)")
    elseif e isa HTTP.RequestError
        println("Request failed: $(e.error)")
    else
        rethrow()
    end
end
```

## Cookie Handling

The cookie persistence system has been reimplemented to be threadsafe and more robust:

```julia
# Creating a custom cookie jar
jar = HTTP.CookieJar()

# Using it for requests
response = HTTP.get("https://example.com", cookiejar=jar)

# Checking cookies
cookies = HTTP.getcookies(jar, "example.com")
```

## Other Notable Changes

- **URI Handling**: URIs are now handled by the separate URIs.jl package (this change actually occurred in v1.0)
- **Default Headers**: Headers like `Accept: */*` are now included by default in requests
- **TLS Implementation**: OpenSSL is now the default TLS provider instead of MbedTLS
- **Multithreading**: Improved thread safety throughout the codebase
- **Performance**: Significant performance improvements, especially for high-throughput servers

## Transitioning Tips

1. **Start with client code**: The client API is more similar between versions than the server API
2. **Update error handling**: Review all error handling to work with the more consistent error types
3. **Test thoroughly**: Run your test suite with both versions to identify any subtle differences
4. **Check timeouts**: Review and adjust all timeout-related code as some defaults have changed

## Common Issues During Migration

- If you were relying on `response_stream` being automatically closed, you now need to close it yourself
- If you have custom middleware or request handlers, you may need to adjust them to the updated interfaces
- Custom client-side layers from v1.x are not compatible with v2.0 and will need to be reimplemented
- WebSocket handling code may need adjustments even though the API is similar

For more detailed information on specific topics, consult the full HTTP.jl v2.0.0 documentation.