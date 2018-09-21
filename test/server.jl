using Distributed

while nworkers() < 5
    addprocs(1)
end

@everywhere using HTTP, Sockets, Test

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
                # println("sending request...")
                @async push!(rr, HTTP.request("GET", "$url/$ii", [], body))
            end
            return rr
        end)("$url/$i", m))
    end
    return join([String(x) for x in vcat(r...)], "\n")
end

@testset "HTTP.listen" begin

port = 8087 # rand(8000:8999)

# echo response
handler = (req) -> begin
    req.response.body = req.body
    return req.response
end

tsk = @async HTTP.listen(handler, "127.0.0.1", port)

handler2 = HTTP.Servers.RequestHandlerFunction(handler)

tsk2 = @async HTTP.listen(handler2, "127.0.0.1", port+100)
sleep(3.0)

r = testget("http://127.0.0.1:$port")
@test occursin(r"HTTP/1.1 200 OK", r)

r = testget("http://127.0.0.1:$(port+100)")
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
x = "GET / HTTP/1.1\r\n$(repeat("Foo: Bar\r\n", 10000))\r\n";
@show length(x)
write(tcp, "GET / HTTP/1.1\r\n$(repeat("Foo: Bar\r\n", 10000))\r\n")
sleep(0.1)
@test occursin(r"HTTP/1.1 413 Request Entity Too Large", String(read(tcp)))

# invalid HTTP
tcp = Sockets.connect(ip"127.0.0.1", port)
write(tcp, "GET / HTP/1.1\r\n\r\n")
sleep(0.1)
@test occursin(r"HTTP/1.1 400 Bad Request", String(readavailable(tcp)))

# no URL
tcp = Sockets.connect(ip"127.0.0.1", port)
write(tcp, "SOMEMETHOD HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
sleep(0.1)
r = String(readavailable(tcp))
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

println("client:")
println(client)
@test occursin("HTTP/1.1 200 OK\r\n", client)
@test occursin("Transfer-Encoding: chunked\r\n", client)
@test occursin("Body of Request", client)

# keep-alive vs. close: issue #81
port += 1
tsk = @async HTTP.listen("127.0.0.1", port,verbose=true) do r::HTTP.Request
    HTTP.Response("Hello")
end
sleep(2.0)
tcp = Sockets.connect(ip"127.0.0.1", port)
write(tcp, "GET / HTTP/1.0\r\n\r\n")
sleep(0.5)
client = String(readavailable(tcp))
@show client
@test client == "HTTP/1.1 200 OK\r\n\r\nHello"

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
    r = HTTP.Response(200, req.headers)
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
