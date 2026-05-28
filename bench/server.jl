# Matching benchmark server. Same code runs against HTTP 1.x and 2.0.
#
# Three endpoints:
#   GET /tiny   -> 200 OK, no body                      ("empty")
#   GET /json   -> ~200 byte JSON object                ("small")
#   GET /large  -> ~100 KB body of repeated bytes       ("large")
#
# Usage: julia --project=. server.jl <port>

using HTTP

const SMALL_JSON = """{"id":1,"name":"alice","email":"alice@example.com","tags":["admin","reviewer"],"created_at":"2024-01-01T12:00:00Z","status":"active","login_count":42}"""
const LARGE_BODY = repeat("x", 100 * 1024)  # 100 KB

const TINY_HEADERS = ["Content-Length" => "0"]
const JSON_HEADERS = ["Content-Type" => "application/json", "Content-Length" => string(length(SMALL_JSON))]
const LARGE_HEADERS = ["Content-Type" => "application/octet-stream", "Content-Length" => string(length(LARGE_BODY))]

function handler(req::HTTP.Request)
    t = req.target
    if t == "/tiny"
        return HTTP.Response(200, TINY_HEADERS)
    elseif t == "/json"
        return HTTP.Response(200, JSON_HEADERS; body = SMALL_JSON)
    elseif t == "/large"
        return HTTP.Response(200, LARGE_HEADERS; body = LARGE_BODY)
    else
        return HTTP.Response(404)
    end
end

port = parse(Int, ARGS[1])
server = HTTP.serve!(handler, "127.0.0.1", port)
println("READY $(HTTP.port(server))")
flush(stdout)
wait(server)
