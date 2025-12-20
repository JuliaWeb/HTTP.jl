"""
Simple server that implements [server-sent events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events),
loosely following [this tutorial](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events).

### Example client code (JS):
```http
<html>
<head>
    <meta charset="UTF-8">
    <title>Server-sent events demo</title>
</head>
<body>
    <h3>Fetched items:</h3>
    <ul id="list"></ul>
</body>
<script>
    const evtSource = new EventSource("http://127.0.0.1:8080/api/events")
    evtSource.onmessage = async function (event) {
        const newElement = document.createElement("li");
        const eventList = document.getElementById("list");
        if (parseFloat(event.data) > 0.5) {
            const r = await fetch("http://127.0.0.1:8080/api/getItems")
            if (r.ok) {
                const body = await r.json()
                newElement.textContent = body;
                eventList.appendChild(newElement);
            }
        }
    }
    evtSource.addEventListener("ping", function(event) {
        console.log('ping:', event.data)
    });
</script>
</html>
```

### Example client code (Julia)
```julia
using HTTP, JSON

# Using sse_callback for automatic SSE parsing:
HTTP.request("GET", "http://127.0.0.1:8080/api/events"; sse_callback = (stream, event) -> begin
    @info "Received event" data=event.data event_type=event.event id=event.id
end)

# Or using HTTP.open for raw streaming:
HTTP.open("GET", "http://127.0.0.1:8080/api/events") do io
    while !eof(io)
        println(String(readavailable(io)))
    end
end
```

### Server code (using HTTP.sse_stream - recommended):
"""
using HTTP, Sockets, JSON

# Simple SSE server using the HTTP.sse_stream helper
function simple_sse_server()
    server = HTTP.serve!(listenany=true) do request
        response = HTTP.Response(200)
        # Add CORS headers for browser clients
        HTTP.setheader(response, "Access-Control-Allow-Origin" => "*")

        # Create SSE stream - automatically sets Content-Type and Cache-Control
        HTTP.sse_stream(response) do stream
            for i in 1:10
                # Write a ping event with timestamp
                write(stream, HTTP.SSEEvent(string(round(Int, time())); event="ping"))

                # Occasionally write a data event
                if rand(Bool)
                    write(stream, HTTP.SSEEvent(string(rand())))
                end
                sleep(1)
            end
        end

        return response
    end
    return server
end

# More complex example with Router
const ROUTER = HTTP.Router()

function getItems(req::HTTP.Request)
    headers = [
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "GET, OPTIONS"
    ]
    if HTTP.method(req) == "OPTIONS"
        return HTTP.Response(200, headers)
    end
    return HTTP.Response(200, headers, JSON.json(rand(2)))
end

# Using HTTP.sse_stream with a request handler
function events_handler(req::HTTP.Request)
    if HTTP.method(req) == "OPTIONS"
        return HTTP.Response(200, [
            "Access-Control-Allow-Origin" => "*",
            "Access-Control-Allow-Methods" => "GET, OPTIONS"
        ])
    end

    response = HTTP.Response(200)
    HTTP.setheader(response, "Access-Control-Allow-Origin" => "*")
    HTTP.sse_stream(response) do stream
        while true
            write(stream, HTTP.SSEEvent(string(round(Int, time())); event="ping"))
            if rand(Bool)
                write(stream, HTTP.SSEEvent(string(rand())))
            end
            sleep(1)
        end
    end

    return response
end

# Alternative: manual SSE using stream handler (lower-level approach)
function events_stream(stream::HTTP.Stream)
    HTTP.setheader(stream, "Access-Control-Allow-Origin" => "*")
    HTTP.setheader(stream, "Access-Control-Allow-Methods" => "GET, OPTIONS")
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")

    if HTTP.method(stream.message) == "OPTIONS"
        return nothing
    end

    while true
        write(stream, "event: ping\ndata: $(round(Int, time()))\n\n")
        if rand(Bool)
            write(stream, "data: $(rand())\n\n")
        end
        sleep(1)
    end
    return nothing
end

HTTP.register!(ROUTER, "GET", "/api/getItems", getItems)
HTTP.register!(ROUTER, "GET", "/api/events", events_handler)

# Start the server in the normal request-handler mode
server = HTTP.serve!(ROUTER, "127.0.0.1", 8080)

# To run the manual stream-handler variant instead, start a separate server:
# stream_server = HTTP.serve!(events_stream, "127.0.0.1", 8081; stream=true)

# Julia client usage with sse_callback
stop = Ref(false)
@async begin
    try
        HTTP.request("GET", "http://127.0.0.1:8080/api/events"; sse_callback = (stream, event) -> begin
            println("Event: ", event.event, " | Data: ", event.data)
            stop[] && close(stream)
        end)
    catch e
        # Connection closed or stopped
    end
end

# run the following to stop the streaming client request
stop[] = true

# close the server which will stop the HTTP server from listening
close(server)
@assert istaskdone(server.task)
