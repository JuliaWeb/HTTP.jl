# HTTP.jl Documentation

## Overview

HTTP.jl provides both client and server functionality for the [http](https://en.wikipedia.org/wiki/Hypertext_Transfer_Protocol) protocol. As a client, it provides the ability to make a wide range of
request, including GET, POST, websocket upgrades, form data, multipart, chunking, and cookie handling.
On the server side, it provides the ability to listen, accept, and route http requests, with middleware and
handler interfaces to provide flexibility in processing responses.

## Quickstart

### Making requests (client)

[`HTTP.request`](@ref) sends an http request and returns a response.

```julia
# make a GET request, both forms are equivalent
resp = HTTP.request("GET", "http://httpbin.org/ip")
resp = HTTP.get("http://httpbin.org/ip")
println(resp.status)
println(String(resp.body))

# make a POST request, sending data via `body` keyword argument
resp = HTTP.post("http://httpbin.org/body"; body="request body")

# include query parameters in a request
# and turn on verbose logging of the request/response process
resp = HTTP.get("http://httpbin.org/anything"; query=["hello" => "world"], verbose=2)
```

### Handling requests (server)

`HTTP.serve`(@ref) allows specifying middleware + handlers for how incoming requests should be processed.

```julia
# authentication middleware to ensure property security
function auth(handler)
    return function(req)
        ident = parse_auth(req)
        if ident === nothing
            # failed to security authentication
            return HTTP.Response(401, "unauthorized")
        else
            # store parsed identity in request context for handler usage
            req.context[:auth] = ident
            # pass request on to handler function for further processing
            return handler(req)
        end
    end
end

# handler function to return specific user's data
function handler(req)
    ident = req.context[:auth]
    return HTTP.Response(200, get_user_data(ident))
end

# start a server listening on port 8081 (default port) for localhost (default host)
# requests will first be handled by teh auth middleware before being passed to the `handler`
# request handler function
HTTP.serve(auth(handler))
```

## Further Documentation

Check out the client and server-specific documentation pages for more in-depth discussions
and examples for the many configurations available.

```@contents
Pages = ["client.md", "server.md", "reference.md"]
```

# manual
  # client
    # making requests
    # sections for keyword args + links to examples
    # utilities
  # server
    # running basic server
    # middleware/handlers framework
    # logfmt"..."