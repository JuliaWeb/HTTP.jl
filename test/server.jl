@testset "HTTP.serve" begin

# test kill switch
server = HTTP.Server()
tsk = @async HTTP.serve(server)
sleep(1.0)
put!(server.in, HTTP.Nitrogen.KILL)
sleep(0.1)
@test istaskdone(tsk)

# test http vs. https

# echo response
serverlog = HTTP.FIFOBuffer()
server = HTTP.Server((req, rep) -> HTTP.Response(String(req)), serverlog)
tsk = @async HTTP.serve(server)
sleep(1.0)
r = HTTP.get("http://127.0.0.1:8081/"; readtimeout=30)

@test HTTP.status(r) == 200
@test String(take!(r)) == ""

print(String(readavailable(serverlog)))

# invalid HTTP
sleep(2.0)
tcp = connect(ip"127.0.0.1", 8081)
write(tcp, "GET / HTP/1.1\r\n\r\n")
sleep(2.0)
log = String(readavailable(serverlog))

print(log)
!HTTP.strict && @test contains(log, "invalid HTTP version")

# bad method
sleep(2.0)
tcp = connect(ip"127.0.0.1", 8081)
write(tcp, "BADMETHOD / HTTP/1.1\r\n\r\n")
sleep(2.0)

log = String(readavailable(serverlog))

print(log)
@test contains(log, "invalid HTTP method")

# Expect: 100-continue
sleep(2.0)
tcp = connect(ip"127.0.0.1", 8081)
write(tcp, "POST / HTTP/1.1\r\nContent-Length: 15\r\nExpect: 100-continue\r\n\r\n")
sleep(2.0)

log = String(readavailable(serverlog))

@test contains(log, "sending 100 Continue response to get request body")
client = String(readavailable(tcp))
@test client == "HTTP/1.1 100 Continue\r\n\r\n"

write(tcp, "Body of Request")
sleep(2.0)
log = String(readavailable(serverlog))
client = String(readavailable(tcp))

println("log:")
println(log)
println()
println("client:")
println(client)
@test contains(client, "HTTP/1.1 200 OK\r\n")
@test contains(client, "Connection: keep-alive\r\n")
@test contains(client, "Content-Length: 15\r\n")
@test contains(client, "\r\n\r\nBody of Request")

put!(server.in, HTTP.Nitrogen.KILL)

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

# tsk = @async HTTP.serve(server, IPv4(0,0,0,0), 8082)
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
tsk = @async HTTP.serve(HTTP.Server((req, res) -> Response("Hello\n"), STDOUT), ip"127.0.0.1", 8083)
sleep(2.0)
r = HTTP.request(HTTP.Request(major=1, minor=0, uri=HTTP.URI("http://127.0.0.1:8083/"), headers=["Host"=>"127.0.0.1:8083"]))
@test HTTP.status(r) == 200
@test HTTP.headers(r)["Connection"] == "close"

# body too big

# other bad requests

end # @testset
