# HTTP.jl Documentation

Welcome to the HTTP.jl docs—a fast, full‑featured HTTP client and server library for Julia.

## Overview

HTTP.jl provides a comprehensive set of tools for sending HTTP requests, building HTTP servers, and managing WebSocket connections. This documentation is organized into the following sections:
- **Installation & Quick Start:** Learn how to install HTTP.jl and see basic examples.
- **Manual Guides:** Detailed instructions on client usage, server setup, middleware, and websockets.
- **API Reference:** An auto‑generated reference listing all public functions and types.

## Installation

To install the stable release from the General registry, run:

```julia
using Pkg
Pkg.add("HTTP")
```

For the latest development version, run:

```julia
using Pkg
Pkg.develop(url="https://github.com/JuliaWeb/HTTP.jl.git")
```

## Quick Start

### Client Usage

A simple example of making a GET request:

```julia
using HTTP

response = HTTP.get("https://api.example.com/data")
println(String(response.body))
```

### Server Usage

An example of a minimal server that responds with "Hello, world!":

```julia
using HTTP

function handle_request(req)
    HTTP.Response(200, "Hello, world!")
end

server = HTTP.serve!(handle_request, "0.0.0.0", 8080)
```

Open [http://localhost:8080](http://localhost:8080) in your browser to see the result. Call `close(server)` to stop the server.

### WebSocket Example

A simple example of connecting to a WebSocket server:

```julia
using HTTP

WebSockets.open("ws://echo.websocket.org") do ws
    WebSockets.send(ws, "Hello WebSocket!")
    message = WebSockets.receive(ws)
    println("Received: ", message)
end
```

## Additional Resources

For more detailed information, please refer to the following guides:

- **Manual Guides:**
  - [Client Guide](manual/client.md)
  - [Server Guide](manual/server.md)
  - [WebSockets](manual/websockets.md)

- **API Reference:**  
  See the [API Reference](api/reference.md) for complete details on all public APIs.

## Contributing & License

Contributions are welcome! Please review the [Contributing Guidelines](CONTRIBUTING.md) for further details. HTTP.jl is distributed under the MIT License—see the [LICENSE](LICENSE) file for more information.