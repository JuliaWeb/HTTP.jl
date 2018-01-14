using HTTP
using HTTP.Test

function testget(url)
    mktempdir() do d
        cd(d) do
            cmd = `"curl -v -s $url > tmpout 2>&1"`
            cmd = `bash -c $cmd`
            #println(cmd)
            run(cmd)
            return String(read(joinpath(d, "tmpout")))
        end
    end
end

@testset "HTTP.Servers.serve" begin

# test kill switch
server = HTTP.Servers.Server()
tsk = @async HTTP.Servers.serve(server)
sleep(1.0)
put!(server.in, HTTP.Servers.KILL)
sleep(2)
@test istaskdone(tsk)


# test http vs. https

# echo response
serverlog = HTTP.FIFOBuffer()
server = HTTP.Servers.Server((req, rep) -> begin
    rep.body = req.body
    return rep
end, serverlog)

server.options.ratelimit=0
tsk = @async HTTP.Servers.serve(server)
sleep(1.0)


r = testget("http://127.0.0.1:8081/")
@test ismatch(r"HTTP/1.1 200 OK", r)

rv = []
n = 3
@sync for i = 1:n
    @async begin
        r = testget(repeat("http://127.0.0.1:8081/$i ", n))
        #println(r)
        push!(rv, r)
    end
    sleep(0.01)
end
for i = 1:n
    @test length(filter(l->ismatch(r"HTTP/1.1 200 OK", l),
                        split(rv[i], "\n"))) == n
end

r = HTTP.get("http://127.0.0.1:8081/"; readtimeout=30)
@test r.status == 200
@test String(r.body) == ""


# invalid HTTP
sleep(2.0)
tcp = connect(ip"127.0.0.1", 8081)
write(tcp, "GET / HTP/1.1\r\n\r\n")
!HTTP.Parsers.strict &&
@test ismatch(r"HTTP/1.1 505 HTTP Version Not Supported", String(read(tcp)))
sleep(2.0)


# no URL
sleep(2.0)
tcp = connect(ip"127.0.0.1", 8081)
write(tcp, "SOMEMETHOD HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
r = String(read(tcp))
!HTTP.Parsers.strict && @test ismatch(r"HTTP/1.1 400 Bad Request", r)
!HTTP.Parsers.strict && @test ismatch(r"invalid URL", r)
sleep(2.0)


# Expect: 100-continue
sleep(2.0)
tcp = connect(ip"127.0.0.1", 8081)
write(tcp, "POST / HTTP/1.1\r\nContent-Length: 15\r\nExpect: 100-continue\r\n\r\n")
sleep(2.0)

log = String(readavailable(serverlog))

#@test contains(log, "sending 100 Continue response to get request body")
client = String(readavailable(tcp))
@test client == "HTTP/1.1 100 Continue\r\n\r\n"


write(tcp, "Body of Request")
sleep(2.0)
#log = String(readavailable(serverlog))
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
tsk = @async HTTP.Servers.serve(HTTP.Servers.Server((req, res) -> (res.body = "Hello\n"; res), STDOUT), ip"127.0.0.1", 8083)
sleep(2.0)
r = HTTP.request("GET", "http://127.0.0.1:8083/", ["Host"=>"127.0.0.1:8083"]; http_version=v"1.0")
@test r.status == 200
#@test HTTP.header(r, "Connection") == "close"

# body too big

# other bad requests

end # @testset
