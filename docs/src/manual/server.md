# HTTP Server Guide

This document provides a comprehensive overview of the server functionality in HTTP.jl. It covers creating and managing an `HTTP.Server`, using the `HTTP.serve!` function with its many keyword arguments, understanding how handler functions work (including middleware), and a detailed explanation of the `HTTP.Router` for routing requests.

## Overview

HTTP.jl's server interface lets you build and run HTTP servers with ease. You can manage the server lifecycle with functions such as `isopen`, `close`, and `wait`. In addition, you can define request handlers, wrap them with middleware to extend or transform behavior, and use the `HTTP.Router` to organize and route requests based on method and URL.

## Server Lifecycle Management

An `HTTP.Server` object encapsulates a running server instance. Key lifecycle functions include:

- **`isopen(server)`**  
  Checks whether the server is currently running.

- **`close(server)`**  
  Closes the server and releases any associated resources.

- **`wait(server)`**  
  Will block until the server is closed.

### Example

```julia
using HTTP

# Define a simple request handler
function handle_request(req)
    return HTTP.Response(200, "Hello from HTTP.jl server!")
end

# Start the server
server = HTTP.serve!(handle_request, "127.0.0.1", 8080)

# Check if the server is running
if HTTP.isopen(server)
    println("Server is running on http://127.0.0.1:8080")
end

# Later, close the server
HTTP.close(server)
```

## Using HTTP.serve!

The `HTTP.serve!` function is the primary entry point for starting an HTTP server. It accepts a handler function along with many keyword arguments that configure the server.

### Syntax

```julia
HTTP.serve!(handler_function, host::AbstractString="127.0.0.1", port::Integer=8080;
    allocator = default_aws_allocator(),
    bootstrap::Ptr{aws_server_bootstrap} = default_aws_server_bootstrap(),
    endpoint = nothing,
    listenany::Bool = false,
    access_log::Union{Nothing, Function} = nothing,
    # Socket options
    socket_options = nothing,
    socket_domain = :ipv4,
    connect_timeout_ms::Integer = 3000,
    keep_alive_interval_sec::Integer = 0,
    keep_alive_timeout_sec::Integer = 0,
    keep_alive_max_failed_probes::Integer = 0,
    keepalive::Bool = false,
    # TLS options
    tls_options = nothing,
    ssl_cert = nothing,
    ssl_key = nothing,
    ssl_capath = nothing,
    ssl_cacert = nothing,
    ssl_insecure::Bool = false,
    ssl_alpn_list = "h2;http/1.1",
    initial_window_size = typemax(UInt64)
)
```

### Keyword Arguments Description

- **`listenany`**: Boolean indicating whether to listen on any available port. If `true`, the `port` argument will be used as a starting port, and the server will attempt to bind to the next available port if the specified port is already in use.
- **`access_log`**: A function to log access details, like as returned by the `logfmt"..."` string macro. The function takes an `HTTP.Stream` as input and returns the string to log. If `nothing`, no access logging is performed (default).
-- Socket options:
  - **`socket_options`**: Custom AWS socket options struct.
  - **`socket_domain`**: Domain type (e.g. `:ipv4` or `:ipv6`).
  - **`connect_timeout_ms`**: Connection timeout in milliseconds. Default is 3000 ms.
  - **`keep_alive_interval_sec`**: Interval for sending keep-alive messages in seconds.
  - **`keep_alive_timeout_sec`**: Timeout for keep-alive responses in seconds.
  - **`keep_alive_max_failed_probes`**: Maximum number of failed keep-alive probes allowed.
  - **`keepalive`**: Boolean to enable socket keepalive.
-- TLS options:
  - **`tls_options`**: Custom AWS TLS configuration options.
  - **`ssl_cert`**: Path to the SSL certificate file.
  - **`ssl_key`**: Path to the SSL key file.
  - **`ssl_capath`**: Path to the directory containing CA certificates.
  - **`ssl_cacert`**: Path to the CA certificate file.
  - **`ssl_insecure`**: Boolean flag to disable SSL certificate verification.
  - **`ssl_alpn_list`**: List of ALPN protocols (e.g., `"h2;http/1.1"`).
-- AWS runtime options -
  - **`allocator`**: The AWS allocator to use for AWS-allocated memory while handling connections and requests.
  - **`bootstrap`**: Pointer to an AWS server bootstrap.
  - **`endpoint`**: Custom AWS endpoint for binding the server.

### Example

```julia
using HTTP

function handle_request(req)
    return HTTP.Response(200, "Hello, customized server!")
end

server = HTTP.serve!(handle_request, "127.0.0.1", 8080;
    connect_timeout_ms = 5000,
    keep_alive_interval_sec = 30,
    ssl_insecure = false
)

println("Server started on http://127.0.0.1:8080")
```

## Handlers and Middleware

### Handler Functions

A **Handler** is a function that accepts an `HTTP.Request` (or a stream in advanced cases) and returns an `HTTP.Response`. This is the fundamental building block of how the server processes requests.

Example of a simple handler:

```julia
function simple_handler(req)
    return HTTP.Response(200, "Simple response")
end
```

More involved handler:
```julia
using HTTP, JSON

function advanced_handler(req)
    # Prepare custom headers
    headers = [
        "Content-Type" => "application/json",
        "X-Custom-Header" => "AdvancedExample"
    ]
    
    # Set a non-200 status code (for example, 404 Not Found)
    status_code = 404
    
    # Build a JSON response body with error details
    body = JSON.json(Dict(
        "error" => true,
        "message" => "Resource not found",
        "requested_path" => req.path
    ))
    
    return HTTP.Response(status_code, headers, body)
end
```

### Middleware

**Middleware** are functions that wrap a handler to add pre‑ or post‑processing steps. They are useful for logging, authentication, modifying requests/responses, and more. You can think of a "middleware" as a function that takes a
handler function as input and returns a new function that acts as a handler. The middleware just should most likely
ensure that it calls the original handler at some point.

Example of a logging middleware:

```julia
function logging_middleware(handler)
    return function(req)
        @info "Request received for " * req.path
        return handler(req)
    end
end

# Wrap the simple handler with the middleware and pass the resulting modified handler to serve!
HTTP.serve!(logging_middleware(simple_handler), "127.0.0.1", 8080)
```

### HTTP.Router

The **HTTP.Router** provides a structured way to route incoming requests based on their URL path and HTTP method. It supports:
- Registering routes using `HTTP.register!`.
- Extracting parameters from URL patterns.
- Retrieving routing metadata such as the original route string and path parameters.

#### Creating and Using a Router

```julia
using HTTP

router = HTTP.Router()

# Register a route for GET requests to "/api/data"
HTTP.register!(router, "GET", "/api/data") do req
    return HTTP.Response(200, "Data for GET requests")
end

# Register a route with a path parameter, e.g., "/api/item/{id}"
HTTP.register!(router, "GET", "/api/item/{id}") do req
    id = HTTP.getparam(req, "id")
    return HTTP.Response(200, "Item ID: " * id)
end

# Use the router as your server handler
server = HTTP.serve!(router, "127.0.0.1", 8080)
```

The router also offers helper functions:
- **`HTTP.getroute(req)`**: Returns the original registered route.
- **`HTTP.getparams(req)`**: Returns a dictionary of URL parameters.
- **`HTTP.getparam(req, name, default)`**: Returns the value of a specific parameter, with an optional default.
