@testset "HTTP.Headers" begin
    HTTP.Headers{String,String}()
    HTTP.Headers()

    @test_throws ErrorException HTTP.Headers("accept" => "a", "Accept" => "b")

    h = HTTP.Headers(string(c) => "b" for c in "abcd")
    first(h)

    @test haskey(h, "c")
    @test in("c" => "b", h)
    @test in("c", keys(h))
    @test in("C", keys(h))
    @test !in("c", collect(keys(h)))
    @test in("C", collect(keys(h)))

    h["eXcept-this"] = "true"
    @test h["exCept-This"] == "true"
    @test get(h, "exCept-This", "") == "true"
    @test get!(() -> "def", h, "not fixable") == "def"
    @test get!(h, "not-valid", "ault") == "ault"
    @test h["not-valid"] == "ault"

    pluto = "♇"
    h["C"] = pluto
    @test pop!(h, "C") == pluto
    @test delete!(h, "a") == h
    @test filter!((k, v) -> k != "D", h) == h

    h["bλ-a"] = "a"
    h["b>a"] = ">"

    ks = ["B", "Except-This", "not fixable", "Not-Valid", "bλ-a", "b>a"]
    @test Set(ks) == Set(keys(h))

    @test length(h) == length(ks)
    @test !isempty(h)
    @test similar(h) == HTTP.Headers()
    empty!(h)
    @test length(h) == 0
    @test isempty(h)

    mk_h() = HTTP.Headers("server" => "x", "mime-version" => "y")
    h = mk_h()
    o = HTTP.Headers("Server" => "z", "to" => "q")
    hm_expected = HTTP.Headers("Server" => "z", "Mime-Version" => "y", "To" => "q")

    hm = merge(h, o)
    @test hm == hm_expected
    @test h == mk_h()

    hm_bang = merge!(h, o)
    @test h == hm_expected
    @test hm_bang === h

    hc = copy(h)
    filter!((k, v) -> v != "y", hc)
    @test h == hm_expected
    @test hc != hm_expected

    @test filter((k, v) -> v == "q", h) == HTTP.Headers("To" => "q")
    @test h == hm_expected
end
