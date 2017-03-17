@testset "HTTP.serve" begin

# test kill switch
server = HTTP.Server()
tsk = @async HTTP.serve(server)
sleep(1.0)
put!(server.in, HTTP.KILL)
sleep(0.1)
@test istaskdone(tsk)

# test http vs. https

# echo response
serverlog = HTTP.FIFOBuffer()
server = HTTP.Server((req, rep) -> Response(String(req)), serverlog)
tsk = @async HTTP.serve(server)
sleep(1.0)
r = HTTP.get("http://127.0.0.1:8081/"; readtimeout=30)

@test HTTP.status(r) == 200
@test take!(String, r) == ""

print(readstring(serverlog))

# invalid HTTP
sleep(2.0)
tcp = connect(ip"127.0.0.1", 8081)
write(tcp, "GET / HTP/1.1\r\n\r\n")
sleep(2.0)
log = readstring(serverlog)

print(log)
@test contains(log, "invalid HTTP version")

# bad method
sleep(2.0)
tcp = connect(ip"127.0.0.1", 8081)
write(tcp, "BADMETHOD / HTTP/1.1\r\n\r\n")
sleep(2.0)

log = readstring(serverlog)

print(log)
@test contains(log, "invalid HTTP method")

# Expect: 100-continue
sleep(2.0)
tcp = connect(ip"127.0.0.1", 8081)
write(tcp, "POST / HTTP/1.1\r\nContent-Length: 15\r\nExpect: 100-continue\r\n\r\n")
sleep(2.0)

log = readstring(serverlog)

@test contains(log, "sending 100 Continue response to get request body")
client = String(readavailable(tcp))
@test client == "HTTP/1.1 100 Continue\r\n\r\n"

write(tcp, "Body of Request")
sleep(2.0)
log = readstring(serverlog)
client = String(readavailable(tcp))

@test contains(client, "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 15\r\n")
@test contains(client, "\r\n\r\nBody of Request")

put!(server.in, HTTP.KILL)

# test readtimeout, before sending anything and then mid-request

# header overflow

# upgrade request

# handler throw error

# keep-alive vs. close

# body too big

# other bad requests

end # @testset