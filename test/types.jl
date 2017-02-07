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

show(HTTP.Response(200))
showcompact(HTTP.Response(200))

show(HTTP.Request())
showcompact(HTTP.Request())

end