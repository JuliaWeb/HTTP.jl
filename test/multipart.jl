@testset "HTTP.Form for multipart/form-data" begin
    headers = Dict("User-Agent" => "HTTP.jl")
    body = HTTP.Form(Dict())
    uri = "https://httpbin.org/post"
    uri_put = "https://httpbin.org/put"
    @testset "Setting of Content-Type" begin
        for r in (HTTP.request("POST", uri, headers, body), HTTP.post(uri, headers, body),
                  HTTP.request("PUT", uri_put, headers, body), HTTP.put(uri_put, headers, body))
            @test r.status == 200
            json = JSON.parse(IOBuffer(HTTP.payload(r)))
            @test startswith(json["headers"]["Content-Type"], "multipart/form-data; boundary=")
        end
    end
    @testset "Deprecation of HTTP.post without header for body::Form" begin
        proj = normpath(joinpath(pathof(HTTP), "..", "..", "Project.toml"))
        # Extract version = "(...)" from Project.toml
        vers = VersionNumber(match(r"^version\s*=\s*\"(.*?)\"$"m, read(proj, String)).captures[1])
        if vers.minor == 9 && vers.major == 0 # Keep deprecation around for at least the 0.9 release series
            depwarn_flag = Base.JLOptions().depwarn
            if depwarn_flag == 0 # silent
                @test @test_logs HTTP.post(uri, body).status == 200
            elseif depwarn_flag == 1 # warning
                @test @test_logs (:warn, r"deprecated") HTTP.post(uri, body).status == 200
            else # depwarn_flag == 2 # error
                @test_throws ErrorException HTTP.post(uri, body)
            end
        else # Next breaking release
            try
                HTTP.post(uri, body)
            catch e
                if !(e isa MethodError)
                    @warn "Deprecation for HTTP.post(uri, body) should be removed."
                end
            end
        end
    end
    @testset "HTTP.Multipart ensure show() works correctly" begin
        # testing that there is no error in printing when nothing is set for filename
        str = sprint(show, (HTTP.Multipart(nothing, IOBuffer("some data"), "plain/text", "", "testname")))
        @test findfirst("contenttype=\"plain/text\"", str) !== nothing
    end
    @testset "HTTP.Multipart test constructor" begin
        @test_nowarn HTTP.Multipart(nothing, IOBuffer("some data"), "plain/text", "", "testname")
        @test_throws MethodError HTTP.Multipart(nothing, "some data", "plain/text", "", "testname")
    end

    @testset "Boundary" begin
        @test HTTP.Form(Dict()) isa HTTP.Form
        @test HTTP.Form(Dict(); boundary="a") isa HTTP.Form
        @test HTTP.Form(Dict(); boundary=" Aa1'()+,-.:=?") isa HTTP.Form
        @test HTTP.Form(Dict(); boundary='a'^70) isa HTTP.Form
        @test_throws ArgumentError HTTP.Form(Dict(); boundary="")
        @test_throws ArgumentError HTTP.Form(Dict(); boundary='a'^71)
        @test_throws ArgumentError HTTP.Form(Dict(); boundary="a ")
    end
end
