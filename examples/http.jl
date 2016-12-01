using HttpServer

http = HttpHandler() do req::Request, res::Response
    Response("Hello World")
end
http.events["listen"] = (saddr) -> println("Running on https://$saddr (Press CTRL+C to quit)")

server = Server(http)
run(server, host=IPv4(127,0,0,1), port=8000)
