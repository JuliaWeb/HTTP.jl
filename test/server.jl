@static if VERSION >= v"0.7.0-DEV.2915"
using Distributed
end
while nworkers() < 5
    addprocs(1)
end

@everywhere using HTTP
@static if VERSION < v"0.7.0-DEV.2005"
    @everywhere using Base.Test
else
    @everywhere using Test
end

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

port = rand(8000:8999)

# test kill switch
server = HTTP.Servers.Server()
tsk = @async HTTP.Servers.serve(server, "localhost", port)
sleep(1.0)
put!(server.in, HTTP.Servers.KILL)
sleep(2)
@test istaskdone(tsk)


# test http vs. https

# echo response
server = HTTP.Servers.Server((req) -> begin
    req.response.body = req.body
    return req.response
end, STDOUT)

server.options.ratelimit=0
tsk = @async HTTP.Servers.serve(server, "localhost", port)
sleep(1.0)


r = testget("http://127.0.0.1:$port/")
@test contains(r, r"HTTP/1.1 200 OK")

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
    @test length(filter(l->contains(l, r"HTTP/1.1 200 OK"),
                        split(rv[i], "\n"))) == n * m
end

r = HTTP.get("http://127.0.0.1:$port/"; readtimeout=30)
@test r.status == 200
@test String(r.body) == ""


# large headers
tcp = connect(ip"127.0.0.1", port)
x = "GET / HTTP/1.1\r\n$(repeat("Foo: Bar\r\n", 10000))\r\n"
@show length(x)
write(tcp, "GET / HTTP/1.1\r\n$(repeat("Foo: Bar\r\n", 10000))\r\n")
sleep(0.1)
@test contains(String(read(tcp)), r"HTTP/1.1 413 Request Entity Too Large")

# invalid HTTP
tcp = connect(ip"127.0.0.1", port)
sleep(0.1)
write(tcp, "GET / HTP/1.1\r\n\r\n")
@test contains(String(read(tcp)), r"HTTP/1.1 400 Bad Request")


# no URL
tcp = connect(ip"127.0.0.1", port)
write(tcp, "SOMEMETHOD HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
sleep(0.1)
r = String(read(tcp))
@test contains(r, r"HTTP/1.1 400 Bad Request")


# Expect: 100-continue
tcp = connect(ip"127.0.0.1", port)
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
@test contains(client, "HTTP/1.1 200 OK\r\n")
@test contains(client, "Transfer-Encoding: chunked\r\n")
@test contains(client, "Body of Request")

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
tsk = @async HTTP.Servers.serve(HTTP.Servers.Server((req) -> (req.response.body = "Hello\n"; req.response), STDOUT), ip"127.0.0.1", port)
sleep(2.0)
r = HTTP.request("GET", "http://127.0.0.1:$port/", ["Host"=>"127.0.0.1:$port"]; http_version=v"1.0")
@test r.status == 200
#@test HTTP.header(r, "Connection") == "close"

# body too big

# other bad requests

end # @testset
