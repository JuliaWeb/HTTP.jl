"""
# Multipart/Mixed Batch Request Example

This example demonstrates a simple batch API server and client using multipart/mixed
content type. The server accepts multiple HTTP requests in a single batch and returns
multiple responses.

## Running the Example

```julia
include("examples/batch_server_example.jl")
```

This will:
1. Start a local batch server on port 8081
2. Send a batch request with 3 sub-requests
3. Parse the batch response
4. Display the results
5. Shutdown the server
"""

using HTTP

# Simple in-memory data store for the example
const DATA_STORE = Dict{String, Any}(
    "1" => Dict("id" => "1", "name" => "Alice", "role" => "Developer"),
    "2" => Dict("id" => "2", "name" => "Bob", "role" => "Designer"),
    "3" => Dict("id" => "3", "name" => "Charlie", "role" => "Manager"),
)

"""
Parse a raw HTTP request string into method, path, headers, and body
"""
function parse_http_request(request_str::String)
    lines = split(request_str, "\r\n")

    # Parse request line (e.g., "GET /api/users/1 HTTP/1.1")
    request_line = split(lines[1], " ")
    method = request_line[1]
    path = request_line[2]

    # Find headers and body separator
    separator_idx = findfirst(==(""), lines)

    # Parse headers
    headers = HTTP.Headers()
    if separator_idx !== nothing
        for line in lines[2:separator_idx-1]
            if occursin(":", line)
                key, value = split(line, ":", limit=2)
                push!(headers, strip(key) => strip(value))
            end
        end

        # Parse body
        body = join(lines[separator_idx+1:end], "\r\n")
    else
        body = ""
    end

    return method, path, headers, body
end

"""
Handle individual API requests
"""
function handle_api_request(method::AbstractString, path::AbstractString, body::AbstractString)
    # Extract user ID from path like /api/users/1
    user_id_match = match(r"/api/users/(\d+)", path)

    if user_id_match === nothing
        return HTTP.Response(404, "Not Found")
    end

    user_id = user_id_match.captures[1]

    if method == "GET"
        if haskey(DATA_STORE, user_id)
            # Simple JSON serialization
            user = DATA_STORE[user_id]
            json_str = "{\"id\":\"$(user["id"])\",\"name\":\"$(user["name"])\",\"role\":\"$(user["role"])\"}"
            return HTTP.Response(200,
                ["Content-Type" => "application/json"],
                json_str)
        else
            return HTTP.Response(404, "User not found")
        end
    elseif method == "DELETE"
        if haskey(DATA_STORE, user_id)
            delete!(DATA_STORE, user_id)
            return HTTP.Response(204, "")
        else
            return HTTP.Response(404, "User not found")
        end
    else
        return HTTP.Response(405, "Method Not Allowed")
    end
end

"""
Batch request handler - accepts multipart/mixed batch requests
"""
function batch_handler(req::HTTP.Request)

    # Check if this is a batch request
    content_type = HTTP.header(req, "Content-Type", "")

    if !startswith(content_type, "multipart/mixed")
        return HTTP.Response(400, "Expected multipart/mixed content type")
    end

    # Manually read the request body if it's not buffered
    # In HTTP 2.0 server, bodies default to EmptyBody for streaming
    req = if req.body isa HTTP.EmptyBody || req.body isa HTTP.AbstractBody
        HTTP._buffer_server_request(req)
    else
        req
    end

    # Parse the batch request
    parts = HTTP.parse_multipart_mixed(req)

    if parts === nothing
        return HTTP.Response(400, "Failed to parse batch request")
    end

    println("Received batch request with $(length(parts)) parts\n")

    # Process each sub-request
    response_parts = HTTP.Multipart[]

    try
        for (i, part) in enumerate(parts)
            local response  # Declare response in loop scope
            try
                # Read the sub-request
                request_str = String(read(part))
                println("Processing sub-request $i...")

                # Parse the sub-request
                method, path, sub_headers, sub_body = parse_http_request(request_str)

                # Handle the sub-request
                response = handle_api_request(method, path, sub_body)
                println("  → $method $path: $(response.status)")
            catch e
                println("  ERROR: $e")
                # Create an error response
                response = HTTP.Response(500, "Internal Server Error: $e")
            end

        # Format the response as an HTTP message
        # Simple status text mapping
        status_text = response.status == 200 ? "OK" :
                      response.status == 204 ? "No Content" :
                      response.status == 404 ? "Not Found" :
                      response.status == 405 ? "Method Not Allowed" :
                      response.status == 500 ? "Internal Server Error" : "Unknown"
        response_str = "HTTP/1.1 $(response.status) $status_text\r\n"
        for (key, value) in response.headers
            response_str *= "$key: $value\r\n"
        end
        response_str *= "\r\n"
        if !isempty(response.body)
            response_str *= String(response.body)
        end

        # Create a multipart for the response
        push!(response_parts, HTTP.Multipart(
            nothing,
            IOBuffer(response_str),
            "application/http",
            "binary",
            ""
        ))
    end

    # Create the batch response
    batch_response = HTTP.Batch(response_parts)
    response_body = read(batch_response)

    println("\nBatch response created with $(length(response_parts)) parts ($(length(response_body)) bytes)\n")

    return HTTP.Response(200,
        ["Content-Type" => HTTP.content_type(batch_response)],
        response_body)
    catch e
        println("FATAL ERROR: $e")
        return HTTP.Response(500, "Server error: $e")
    end
end

"""
Start the batch server
"""
function start_batch_server(port=8081)
    # Use a simple handler function instead of Router
    server = HTTP.serve!(batch_handler, "127.0.0.1", port; reuseaddr=true)
    println("Batch server started on http://127.0.0.1:$port")
    println("Endpoint: POST http://127.0.0.1:$port/\$batch")

    return server
end

"""
Send a batch request to the server
"""
function send_batch_request(url="http://127.0.0.1:8081/\$batch")
    println("\n" * "="^60)
    println("Sending batch request with 3 sub-requests")
    println("="^60)

    # Create sub-requests as HTTP messages
    subrequest1 = """GET /api/users/1 HTTP/1.1\r
Host: example.com\r
\r
"""

    subrequest2 = """GET /api/users/2 HTTP/1.1\r
Host: example.com\r
\r
"""

    subrequest3 = """DELETE /api/users/3 HTTP/1.1\r
Host: example.com\r
\r
"""

    # Create multipart parts for each sub-request
    parts = [
        HTTP.Multipart(nothing, IOBuffer(subrequest1), "application/http", "binary", ""),
        HTTP.Multipart(nothing, IOBuffer(subrequest2), "application/http", "binary", ""),
        HTTP.Multipart(nothing, IOBuffer(subrequest3), "application/http", "binary", ""),
    ]

    # Create the batch request body using Batch()
    batch = HTTP.Batch(parts)
    batch_content_type = HTTP.content_type(batch)  # Get this before reading
    batch_body = read(batch)  # Read the body into bytes

    println("Batch body size: $(length(batch_body)) bytes")

    # Send the batch request
    response = HTTP.post(url,
        ["Content-Type" => batch_content_type,
         "Content-Length" => string(length(batch_body))],
        batch_body)

    println("\n" * "="^60)
    println("Received batch response: $(response.status)")
    println("="^60)

    # Parse the batch response
    response_parts = HTTP.parse_multipart_mixed(response)

    if response_parts === nothing
        println("Failed to parse batch response")
        return
    end

    println("\nParsed $(length(response_parts)) responses:\n")

    # Display each sub-response
    for (i, part) in enumerate(response_parts)
        response_str = String(read(part))
        println("Sub-response $i:")
        println("-" ^ 40)
        println(response_str)
        println()
    end
end

"""
Run the complete example
"""
function run_example()
    # Start the server
    server = start_batch_server(8081)

    # Give the server a moment to start
    sleep(1)

    try
        # Send a batch request
        send_batch_request()
    finally
        # Shutdown the server
        println("\n" * "="^60)
        println("Shutting down server...")
        println("="^60)
        close(server)
    end
end

# Run the example if this file is executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    run_example()
end
