@testset "HTTPVersion" begin

# Constructors
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

# Important that we can parse a string into a `HTTPVersion` without allocations,
# as we do this for every request/response. Similarly if we then want a `VersionNumber`.
@test @allocated(HTTPVersion("1.1")) == 0
@test @allocated(VersionNumber(HTTPVersion("1.1"))) == 0

# Test comparisons with `VersionNumber`s
req = HTTP.Request("GET", "http://httpbin.org/anything")
res = HTTP.Response(200)
for r in (req, res)
    @test r.version == v"1.1"
    @test r.version <= v"1.1"
    @test r.version < v"1.2"
end

end # testset
