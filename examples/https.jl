# Generate a certificate and key if they do not exist

rel(p::String) = joinpath(dirname(@__FILE__), p)
if !isfile(rel("keys/server.crt"))
  @unix_only begin
    run(`mkdir -p $(rel("keys"))`)
    run(`openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout
      $(rel("keys/server.key")) -out $(rel("keys/server.crt"))`)
  end
end

# Simple HTTPS Server

using MbedTLS, HttpServer

http = HttpHandler() do req, res
    Response("Hello Secure World!")
end

server = Server(http)
cert = MbedTLS.crt_parse_file(rel("keys/server.crt"))
key = MbedTLS.parse_keyfile(rel("keys/server.key"))

run(server, port=8002, ssl=(cert, key))
