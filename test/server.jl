@testset "HTTP.serve" begin

# test kill switch
server = HTTP.Server()
tsk = @async HTTP.serve(server)
sleep(1.0)
put!(server.comm, HTTP.KILL)
sleep(0.1)
@test istaskdone(tsk)

# test http vs. https

# hello world response
server = HTTP.Server()
tsk = @async HTTP.serve(server)
sleep(1.0)
r = HTTP.get("http://127.0.0.1:8081/"; readtimeout=30)

@test HTTP.status(r) == 200

put!(server.comm, HTTP.KILL)

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