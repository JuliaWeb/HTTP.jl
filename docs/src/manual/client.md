# HTTP Client Guide

This guide provides an in-depth look at HTTP.jl’s client functionality. It covers the primary function for making requests, the available helper functions, how to configure and use a preconfigured client for advanced use cases, and a brief overview of what happens behind the scenes.

## Overview

HTTP.jl enables you to issue HTTP requests using the primary function `HTTP.request`. In addition, there are convenience functions like `HTTP.get`, `HTTP.post`, `HTTP.put`, `HTTP.delete` etc., which are simply aliases that pass the appropriate HTTP method automatically. You can also pass a wide variety of keyword arguments to control the behavior of both the request and the underlying client.

## The HTTP.request Function

The general form of the request function is:

\`\`\`julia
HTTP.request(method, url[, headers, body]; keyword_arguments...)
\`\`\`

Here, **method** is a string such as `"GET"`, `"POST"`, or `"PUT"`, and **url** can be either a string or a URI.
**headers** is an optional array of key-value pairs, and **body**, also optional, is the request payload. The function returns a `Response` object.

### Helper Functions

- **HTTP.get, HTTP.post, HTTP.put, HTTP.delete, etc.:**  
  These functions are shortcuts for calling `HTTP.request` with the corresponding HTTP method. For example, calling `HTTP.get(url; kwargs...)` is equivalent to calling `HTTP.request("GET", url; kwargs...)`.

### Available Keyword Arguments

The following keyword arguments (which correspond to the non-`scheme`/`host`/`port` fields of `ClientSettings`) allow you to finely control request and client behavior:

- **query**: Any iterable that yields length-2 iterables can be provided as query params that will be joined with the `url` argument. e.g. a `Dict`, `Vector{Pair}`, etc.
- **headers**: Any iterable that yields length-2 iterables can be provided as headers for the HTTP request. Some default headers are set if not provided.
- **client**: A custom-configured `HTTP.Client` can be provided to precisely control settings for classes of requests.
- **verbose**: Controls the verbosity of logging during the request.
-- Request body options:
  - **body**: Can be one of: `AbstractString`, `AbstractVector{UInt8}`, `IO`, `AbstractDict`, or `NamedTuple`. Strings and byte vectors will be sent "as-is. `IO` request bodies will be read completely and then sent. Dicts and namedtuples will be encoded in the `x-www-form-urlencoded` content-type format before being sent.
  - **chunkedbody**: To send a request body in chunks, an iterable must be provided where each element is one of the valid types of request bodies mentioned above.
  - **modifier**: A function of the form `f(request, body) -> newbody`, i.e. that takes the HTTP request object and proposed request body, and can optionally return a new request body. If the modifer only modifies the request object, it should return `nothing`, which will ensure the original request body is sent unmodified.
-- Response options:
  - **response_body**: By default, response bodies are returned as `Vector{UInt8}`. Alternatively, a preallocated `AbstractVector{UInt8}` or any `IO` object can be provided for the response body to be written into.
  - **decompress**: If `true`, the response body will be decompressed if it is compressed. By default, response bodies with the `Content-Encoding: gzip` header are decompressed.
  - **status_exception**: Default `true`. If `true`, an exception will be thrown if the response status code is not in the 200-299 range.
  - **readtimeout**: The maximum time in seconds to wait for a response from the server. Only valid for HTTP/1.1 connections.
-- Redirect options:
  - **redirect**: Default `true`. If `true`, the client will follow redirects.
  - **redirect_limit**: The maximum number of redirects to follow. Default is 3.
  - **redirect_method**: The method to use for redirected requests. Pass `:same` to use the same method as the original request, or the specific method to use (like `:POST`).
  - **forwardheaders**: Default `true`. If `true`, non-sensitive headers from the original request will be forwarded to the redirected request.
-- Authentication options:
  - **username**: The username for basic authentication.
  - **password**: The password for basic authentication.
  - **bearer**: The bearer token for authentication.
-- Cookie options:
  - **cookies**: Default `true`. If `true`, cookies will be stored and sent with subsequent requests that match appropriate domains. If `false`, no cookies will be stored or sent. Can also pass a `Dict` of cookies to send with the request.
  - **cookiejar**: The `HTTP.CookieJar` object to use for storing and matching cookies for requests.
-- Client options:
  -- Socket options:
    - **connect_timeout_ms**: The maximum time in milliseconds to wait for a connection to be established. Default is 3000.
    - **socket_domain**: The socket domain to use for the connection. Default is `:ipv4`. Can also be `:ipv6`.
    - **keep_alive_interval_sec**: The time in seconds to wait before sending a keep-alive probe. Default is 0.
    - **keep_alive_timeout_sec**: The time in seconds to wait for a keep-alive probe response. Default is 0.
    - **keep_alive_max_failed_probes**: The maximum number of failed keep-alive probes before the connection is closed. Default is 0.
    - **keepalive**: Default `false`. If `true`, the connection will utilize keep-alive probes to maintain the connection.
  -- SSL options:
    - **ssl_insecure**: Default `false`. If `true`, SSL certificate verification will be disabled.
    - **ssl_cert**: The path to the SSL certificate file.
    - **ssl_key**: The path to the SSL key file.
    - **ssl_capath**: The path to the directory containing CA certificates.
    - **ssl_cacert**: The path to the CA certificate file.
    - **ssl_alpn_list**: A list of ALPN protocols to use for the connection. Default is `"h2;http/1.1"`.
  -- Proxy options:
    - **proxy_allow_env_var**: Default `true`. If `true`, the `HTTP_PROXY` environment variable will be used to set the proxy settings.
    - **proxy_connection_type**: The type of connection to use for the proxy. Default is `:http`. Can also be `:https`.
    - **proxy_host**: The host of the proxy server.
    - **proxy_port**: The port of the proxy server.
    - **proxy_ssl_cert**: The path to the SSL certificate file for the proxy.
    - **proxy_ssl_key**: The path to the SSL key file for the proxy.
    - **proxy_ssl_capath**: The path to the directory containing CA certificates for the proxy.
    - **proxy_ssl_cacert**: The path to the CA certificate file for the proxy.
    - **proxy_ssl_insecure**: Default `false`. If `true`, SSL certificate verification will be disabled for the proxy.
    - **proxy_ssl_alpn_list**: A list of ALPN protocols to use for the proxy connection. Default is `"h2;http/1.1"`.
  -- Retry options:
    - **max_retries**: The maximum number of times to retry a request. Default is 10.
    - **retry_partition**: Requests utilizing the same retry partition (an arbitrary string) will coordinate retries against each other to not overwhelm a temporarily unresponsive server.
    - **backoff_scale_factor_ms**: The factor by which to scale the backoff time between retries. Default is 25.
    - **max_backoff_secs**: The maximum time in seconds to wait between retries. Default is 20.
    - **retry_timeout_ms**: The maximum time in milliseconds to wait for a retry to complete. Default is 60000.
    - **initial_bucket_capacity**: The initial capacity of the retry bucket. Default is 500.
    - **retry_non_idempotent**: Default `false`. If `true`, non-idempotent requests will be retried.
  -- Connection pool options:
    - **max_connections**: The maximum number of connections to keep open in the connection pool. Default is 512.
    - **max_connection_idle_in_milliseconds**: The maximum time in milliseconds to keep a connection open in the pool. Default is 60000.
  -- AWS runtime options:
    - **allocator**: The allocator to use for AWS-allocated memory during the request.
    - **bootstrap**: The AWS client bootstrap to use for the request.
    - **event_loop_group**: The AWS event loop group to use for the request.

Any combination of these keyword arguments can be passed to `HTTP.request` (or its helper functions) to customize your HTTP requests.

## Examples

### Basic GET Request

\`\`\`julia
using HTTP

response = HTTP.request("GET", "https://httpbin.org/get")
println("Status: ", response.status)
println("Body: ", String(response.body))
\`\`\`

### POST Request with JSON Payload

\`\`\`julia
using HTTP, JSON

payload = JSON.json(Dict("name" => "HTTP.jl", "version" => "2.0"))
headers = ["Content-Type" => "application/json"]

response = HTTP.request("POST", "https://httpbin.org/post"; headers = headers, body = payload)
println("Response: ", String(response.body))
\`\`\`

### GET Request with Query Parameters and Custom Headers

\`\`\`julia
using HTTP

response = HTTP.request(
    "GET",
    "https://httpbin.org/get";
    query = Dict("search" => "Julia HTTP client"),
    headers = ["Accept" => "application/json"]
)
println("Response JSON: ", String(response.body))
\`\`\`

## Preconfigured Clients (Advanced)

For advanced use cases, you can create a custom client with specific parameters for a particular `scheme`, `host`, and `port`. This custom client is preconfigured with your desired connection settings (such as timeouts, retries, and SSL options) and can be passed to any HTTP request function using the `client` keyword. By default, HTTP.jl will create or reuse an existing client that matches the exact combination of `scheme`, `host`, `port`, and all other provided keyword arguments.

For example:

\`\`\`julia
using HTTP

# Instantiate a client with custom settings
custom_client = HTTP.Client(
    "https",
    "api.example.com",
    443;
    connect_timeout_ms = 5000,
    max_retries = 3,
    ssl_insecure = false
    # Additional settings can be specified here...
)

# Use the custom client in a request; subsequent requests with the same parameters will reuse this client
response = HTTP.get("https://api.example.com/data"; client = custom_client)
println(String(response.body))
\`\`\`

## Under the Hood (Advanced)

When you call `HTTP.request`, the following advanced steps occur:

1. **URI Parsing:**  
   The URL is parsed and combined with any query parameters provided.

2. **Client Selection and Initialization:**  
   A client is either chosen from a pool or created based on the provided (or default) settings. Clients are matched using the `scheme`, `host`, `port`, and all other keyword arguments.

3. **Connection Management:**  
   The selected client configures and acquires a connection, using client socket options, TLS configuration, and proxy settings as necessary.

4. **Request Assembly:**  
   A complete request message is constructed with the specified method, path, headers, and body. For chunked transfers, HTTP.jl manages the sequential writing of each chunk.

5. **Retry and Redirect Handling:**  
   Built-in logic handles following redirects and retrying requests based on transient errors and the provided configuration.

6. **Response Processing:**  
   The response is parsed, and if errors occur (as dictated by your settings), an exception is raised.

