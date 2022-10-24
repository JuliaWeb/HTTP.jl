@test HTTPVersion(1) == HTTPVersion(1, 0)
@test HTTPVersion(1) == HTTPVersion("1")
@test HTTPVersion(1) == HTTPVersion("1.0")
@test HTTPVersion(1) == HTTPVersion(v"1")
@test HTTPVersion(1) == HTTPVersion(v"1.0")

@test HTTPVersion(1, 1) == HTTPVersion("1.1")
@test HTTPVersion(1, 1) == HTTPVersion(v"1.1")
@test HTTPVersion(1, 1) == HTTPVersion(v"1.1.0")

@test VersionNumber(HTTPVersion(1)) == v"1"
@test VersionNumber(HTTPVersion(1, 1)) == v"1.1"

req = HTTP.Request("GET", "http://httpbin.org/anything")
res = HTTP.Response(200)
for r in (req, res)
    @test r.version == v"1.1"
    @test r.version <= v"1.1"
    @test r.version < v"1.2"
end
