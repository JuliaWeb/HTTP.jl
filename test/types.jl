@testset "types.jl" begin

@test HTTP.schemetype(TCPSocket) == HTTP.http
@test HTTP.schemetype(HTTP.TLS.SSLContext) == HTTP.https

@test HTTP.not(nothing)
@test !HTTP.not(1)

@test HTTP.status(HTTP.Response(300)) == 300
@test String(HTTP.body(HTTP.Response("hello world"))) == "hello world"
@test HTTP.status(HTTP.Response(300, HTTP.Headers(), "")) == 300

@test HTTP.Response(200) == HTTP.Response(200)

@test string(HTTP.Response(200)) == "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"

io = IOBuffer()
showcompact(io, HTTP.Response(200))
@test String(take!(io)) == "Response(200 OK, 0 headers, 0 bytes in body)"

@test string(HTTP.Request()) == "GET / HTTP/1.1\r\n\r\n"

showcompact(io, HTTP.Request())
@test String(take!(io)) == "Request(\"\", 0 headers, 0 bytes in body)"

end
