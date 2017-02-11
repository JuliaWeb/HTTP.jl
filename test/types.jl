@testset "types.jl" begin

@test HTTP.schemetype(TCPSocket) == HTTP.http
@test HTTP.schemetype(HTTP.TLS.SSLContext) == HTTP.https

@test HTTP.?(Int) == Union{Int, Void}
@test HTTP.isnull(nothing)
@test !HTTP.isnull(1)

@test HTTP.status(HTTP.Response(300)) == 300
@test String(HTTP.body(HTTP.Response("hello world"))) == "hello world"
@test HTTP.status(HTTP.Response(300, Dict{String,String}(), "")) == 300

@test HTTP.Response(200) == HTTP.Response(200)

io = IOBuffer()
show(io, HTTP.Response(200))
@test String(take!(io)) == "HTTP.Response:\n\"\"\"\nHTTP/1.1 200 OK\r\n\r\n\"\"\""

showcompact(io, HTTP.Response(200))
@test String(take!(io)) == "Response(200 OK, 0 headers, 0 bytes in body)"

show(io, HTTP.Request())
@test String(take!(io)) == "HTTP.Request:\n\"\"\"\nGET / HTTP/1.1\r\n\r\n\"\"\""

showcompact(io, HTTP.Request())
@test String(take!(io)) == "Request(\"\", 0 headers, 0 bytes in body)"

end