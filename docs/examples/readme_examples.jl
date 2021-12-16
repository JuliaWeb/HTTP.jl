#CLIENT

#HTTP.request sends a HTTP Request Message and returns a Response Message.

r = HTTP.request("GET", "http://httpbin.org/ip"; verbose=3)
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

HTTP.serve() do request::HTTP.Request
   @show request
   @show request.method
   @show HTTP.header(request, "Content-Type")
   @show HTTP.payload(request)
   try
       return HTTP.Response("Hello")
   catch e
       return HTTP.Response(404, "Error: $e")
   end
end

#WebSocket Examples
@async HTTP.WebSockets.listen("127.0.0.1", UInt16(8081)) do ws
    while !eof(ws)
        data = readavailable(ws)
        write(ws, data)
    end
end

HTTP.WebSockets.open("ws://127.0.0.1:8081") do ws
    write(ws, "Hello")
    x = readavailable(ws)
    @show x
    println(String(x))
end;
x = UInt8[0x48, 0x65, 0x6c, 0x6c, 0x6f]
#Output: Hello

#=Custom HTTP Layer Examples
Notes:
There is no enforcement of a "well-defined" stack, you can insert a layer anywhere in the stack even if it logically does not make sense
When creating a custom layer, you need to create a request(), see below for an example
Custom layers is only implemented with the "low-level" request() calls, not the "convenience" functions such as HTTP.get(), HTTP.put(), etc.
module TestRequest=#
        import HTTP: Layer, request, Response

        abstract type TestLayer{Next <: Layer} <: Layer{Next} end
        export TestLayer, request

        function request(::Type{TestLayer{Next}}, io::IO, req, body; kw...)::Response where Next
                println("Insert your custom layer logic here!")
                return request(Next, io, req, body; kw...)
        end
end

using HTTP
using ..TestRequest

custom_stack = insert(stack(), StreamLayer, TestLayer)

result = request(custom_stack, "GET", "https://httpbin.org/ip")

# Insert your custom layer logic here!

# HTTP.Messages.Response:
# """
# HTTP/1.1 200 OK
# Access-Control-Allow-Credentials: true
# Access-Control-Allow-Origin: *
# Content-Type: application/json
# Date: Fri, 30 Aug 2019 14:13:17 GMT
# Referrer-Policy: no-referrer-when-downgrade
# Server: nginx
# X-Content-Type-Options: nosniff
# X-Frame-Options: DENY
# X-XSS-Protection: 1; mode=block
# Content-Length: 45
# Connection: keep-alive

# {
#   "origin": "--Redacted--"
# }
# """

 