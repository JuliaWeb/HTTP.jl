#CLIENT

#HTTP.request sends a HTTP Request Message and returns a Response Message.

r = HTTP.request("GET", "http://httpbin.org/ip")
println(r.status) 
println(String(r.body)) 

#HTTP.open sends a HTTP Request Message and opens an IO stream from which the Response can be read.
HTTP.open(:GET, "https://tinyurl.com/bach-cello-suite-1-ogg") do http
    open(`vlc -q --play-and-exit --intf dummy -`, "w") do vlc
        write(vlc, http)
    end
end

#SERVERS

#Using HTTP.Servers.listen:
#The server will start listening on 127.0.0.1:8081 by default.

using HTTP

HTTP.listen() do http::HTTP.Stream
    @show http.message
    @show HTTP.header(http, "Content-Type")
    while !eof(http)
        println("body data: ", String(readavailable(http)))
    end
    HTTP.setstatus(http, 404)
    HTTP.setheader(http, "Foo-Header" => "bar")
    HTTP.startwrite(http)
    write(http, "response body")
    write(http, "more response body")
end

#Using HTTP.Handlers.serve:

using HTTP

# HTTP.listen! and HTTP.serve! are the non-blocking versions of HTTP.listen/HTTP.serve
server = HTTP.serve!() do request::HTTP.Request
    @show request
    @show request.method
    @show HTTP.header(request, "Content-Type")
    @show request.body
    try
        return HTTP.Response("Hello")
    catch e
        return HTTP.Response(400, "Error: $e")
    end
 end
 # HTTP.serve! returns an `HTTP.Server` object that we can close manually
 close(server)

#WebSocket Examples
using HTTP.WebSockets
server = WebSockets.listen!("127.0.0.1", 8081) do ws
        for msg in ws
            send(ws, msg)
        end
    end

WebSockets.open("ws://127.0.0.1:8081") do ws
           send(ws, "Hello")
           s = receive(ws)
           println(s)
       end;
Hello
#Output: Hello

close(server)

