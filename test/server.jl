using Distributed

while nworkers() < 5
    addprocs(1)
end

@everywhere using HTTP, HTTP.Sockets
@everywhere using Test


"""
    n: number of remotes
    m: number of async requests per remote
"""
function testget(url, n=1, m=1)
    r = []
    @sync for i in 1:n
        @async push!(r, remote((url, mm) -> begin
            rr = []
            @sync for ii in 1:mm
                l = rand([0,0,10,1000,10000])
                body = Vector{UInt8}(rand('A':'Z', l))
                @async push!(rr, HTTP.request("GET", "$url/$ii", [], body))
            end
            return rr
        end)("$url/$i", m))
    end
    return join([String(x) for x in vcat(r...)], "\n")
end

@testset "HTTP.Servers.serve" begin

port = 8086 # rand(8000:8999)

# test kill switch
server = HTTP.Servers.Server()
tsk = @async HTTP.Servers.serve(server, Sockets.localhost, port)
sleep(1.0)
put!(server.in, HTTP.Servers.KILL)
sleep(2)
@test istaskdone(tsk)


# test http vs. https

# echo response
server = HTTP.Servers.Server((req) -> begin
    req.response.body = req.body
    return req.response
end, stdout)

server.options.ratelimit=0
tsk = @async HTTP.Servers.serve(server, Sockets.localhost, port)
sleep(5.0)


r = testget("http://127.0.0.1:$port")
@test occursin(r"HTTP/1.1 200 OK", r)

rv = []
n = 5
m = 20
@sync for i = 1:n
    @async begin
        r = testget("http://127.0.0.1:$port/$i", n, m)
        #println(r)
        push!(rv, r)
    end
    sleep(0.01)
end
for i = 1:n
    @test length(filter(l->occursin(r"HTTP/1.1 200 OK", l),
                        split(rv[i], "\n"))) == n * m
end

r = HTTP.get("http://127.0.0.1:$port/"; readtimeout=30)
@test r.status == 200
@test String(r.body) == ""


# large headers
tcp = Sockets.connect(ip"127.0.0.1", port)
x = "GET / HTTP/1.1\r\n$(repeat("Foo: Bar\r\n", 10000))\r\n"
@show length(x)
write(tcp, "GET / HTTP/1.1\r\n$(repeat("Foo: Bar\r\n", 10000))\r\n")
sleep(0.1)
@test occursin(r"HTTP/1.1 413 Request Entity Too Large", String(read(tcp)))

# invalid HTTP
tcp = Sockets.connect(ip"127.0.0.1", port)
sleep(0.1)
write(tcp, "GET / HTP/1.1\r\n\r\n")
@test occursin(r"HTTP/1.1 400 Bad Request", String(read(tcp)))


# no URL
tcp = Sockets.connect(ip"127.0.0.1", port)
write(tcp, "SOMEMETHOD HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
sleep(0.1)
r = String(read(tcp))
@test occursin(r"HTTP/1.1 400 Bad Request", r)


# Expect: 100-continue
tcp = Sockets.connect(ip"127.0.0.1", port)
write(tcp, "POST / HTTP/1.1\r\nContent-Length: 15\r\nExpect: 100-continue\r\n\r\n")
sleep(0.1)
client = String(readavailable(tcp))
@test client == "HTTP/1.1 100 Continue\r\n\r\n"


write(tcp, "Body of Request")
sleep(0.1)
client = String(readavailable(tcp))

#println("log:")
#println(log)
#println()
println("client:")
println(client)
@test occursin("HTTP/1.1 200 OK\r\n", client)
@test occursin("Transfer-Encoding: chunked\r\n", client)
@test occursin("Body of Request", client)

put!(server.in, HTTP.Servers.KILL)

# serverlog = HTTP.FIFOBuffer()
# server = HTTP.Server((req, rep) -> begin
#     io = HTTP.FIFOBuffer()
#     @async begin
#         i = 0
#         while true
#             println(io, "data: $(now())\n")
#             sleep(2)
#             i += 1
#             i > 5 && break
#         end
#         close(io)
#     end
#     r = HTTP.Response(200, Dict(
#         "Content-Type" => "text/event-stream",
#         "Cache-Control" => "no-cache",
#         "Connection" => "keep-alive"), io)
# end, serverlog)

# tsk = @async HTTP.Servers.serve(server, IPv4(0,0,0,0), 8082)
# sleep(5.0)
# r = HTTP.get("http://localhost:8082/"; readtimeout=30, verbose=true)
# log = String(read(serverlog))
# println(log)
# @test length(String(r)) > 175

# test readtimeout, before sending anything and then mid-request

# header overflow

# upgrade request

# handler throw error

# keep-alive vs. close: issue #81
port += 1
tsk = @async HTTP.Servers.serve(HTTP.Servers.Server((req) -> HTTP.Response("Hello\n"), stdout), "127.0.0.1", port)
sleep(2.0)
r = HTTP.request("GET", "http://127.0.0.1:$port/", ["Host"=>"127.0.0.1:$port"]; http_version=v"1.0")
@test r.status == 200
#@test HTTP.header(r, "Connection") == "close"

# body too big

# other bad requests

# SO_REUSEPORT
println("Testing server port reuse")
t1 = @async HTTP.listen("127.0.0.1", 8089; reuseaddr=true) do req
    return HTTP.Response(200, "hello world")
end
@test !istaskdone(t1)
sleep(0.5)

println("Starting second server listening on same port")
t2 = @async HTTP.listen("127.0.0.1", 8089; reuseaddr=true) do req
    return HTTP.Response(200, "hello world")
end
@test !istaskdone(t2)
sleep(0.5)

println("Starting server on same port without port reuse (throws error)")
try
    HTTP.listen("127.0.0.1", 8089) do req
        return HTTP.Response(200, "hello world")
    end
catch e
    @test e isa Base.IOError
    @test startswith(e.msg, "listen")
    @test e.code == Base.UV_EADDRINUSE
end

# test automatic forwarding of non-sensitive headers
# this is a server that will "echo" whatever headers were sent to it
t1 = @async HTTP.listen("127.0.0.1", 8090) do req::HTTP.Request
    r = HTTP.Response(200)
    r.headers = req.headers
    return r
end
@test !istaskdone(t1)
sleep(0.5)

# test that an Authorization header is **not** forwarded to a domain different than initial request
r = HTTP.get("http://httpbin.org/redirect-to?url=http://127.0.0.1:8090", ["Authorization"=>"auth"])
@test !HTTP.hasheader(r, "Authorization")

# test that an Authorization header **is** forwarded to redirect in same domain
r = HTTP.get("http://httpbin.org/redirect-to?url=https://httpbin.org/response-headers?Authorization=auth")
@test HTTP.hasheader(r, "Authorization")

end # @testset
