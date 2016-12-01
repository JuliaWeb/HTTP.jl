using HttpServer

http = HttpHandler(Base.PipeServer()) do req::Request, res::Response
    Response("Hello Unix World!")
end
http.events["listen"] = (socket_file) -> println("Listening file $socket_file...")

server = Server(http)
run(server, socket="/tmp/julia.socket")
