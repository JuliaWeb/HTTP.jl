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

readstring(serverlog)

# invalid HTTP
tcp = connect(ip"127.0.0.1", 8081)
write(tcp, "GET / HTP/1.1\r\n\r\n")
sleep(1.0)
log = readstring(serverlog)

@test contains(log, "error parsing request on connection i=1: invalid HTTP version")

# bad method
tcp = connect(ip"127.0.0.1", 8081)
write(tcp, "BADMETHOD / HTTP/1.1\r\n\r\n")
sleep(1.0)

log = readstring(serverlog)

@test contains(log, "error parsing request on connection i=2: invalid HTTP method")

# Expect: 100-continue
tcp = connect(ip"127.0.0.1", 8081)
write(tcp, "POST / HTTP/1.1\r\nContent-Length: 15\r\nExpect: 100-continue\r\n\r\n")
sleep(1.0)

log = readstring(serverlog)

@test contains(log, "sending 100 Continue response to get request body")
client = String(readavailable(tcp))
@test client == "HTTP/1.1 100 Continue\r\n"

write(tcp, "Body of Request")
sleep(1.0)
log = readstring(serverlog)
client = String(readavailable(tcp))

@test client == "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 15\r\nContent-Type: text/html; charset=utf-8\r\nDate: Wed, 15 Mar 2017 07:04:05\r\nContent-Language: en\r\nServer: Julia/0.5.0\r\n\r\nBody of Request"

put!(server.in, HTTP.KILL)

# test readtimeout, before sending anything and then mid-request

# invalid http version

# header overflow

# bad method

# Expect: 100-continue

# upgrade request

# handler throw error

# keep-alive vs. close

# body too big

# other bad requests

end # @testset