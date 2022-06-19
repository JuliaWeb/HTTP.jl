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

HTTP.open("GET", "http://127.0.0.1:8080/api/events") do io
    while !eof(io)
        println(String(readavailable(io)))
    end
end
```

### Server code:
"""
using HTTP, Sockets, JSON

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

function events(stream::HTTP.Stream)
    HTTP.setheader(stream, "Access-Control-Allow-Origin" => "*")
    HTTP.setheader(stream, "Access-Control-Allow-Methods" => "GET, OPTIONS")
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")

    if HTTP.method(stream.message) == "OPTIONS"
        return nothing
    end

    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")
    while true
        write(stream, "event: ping\ndata: $(round(Int, time()))\n\n")
        if rand(Bool)
            write(stream, "data: $(rand())\n\n")
        end
        sleep(1)
    end
    return nothing
end

HTTP.register!(ROUTER, "GET", "/api/getItems", HTTP.streamhandler(getItems))
HTTP.register!(ROUTER, "/api/events", events)

server = HTTP.serve!(ROUTER, "127.0.0.1", 8080; stream=true)

# Julia usage
resp = HTTP.get("http://localhost:8080/api/getItems")

close = Ref(false)
@async HTTP.open("GET", "http://127.0.0.1:8080/api/events") do io
    while !eof(io) && !close[]
        println(String(readavailable(io)))
    end
end

# run the following to stop the streaming client request
close[] = true

# close the server which will stop the HTTP server from listening
close(server)
@assert istaskdone(server.task)
