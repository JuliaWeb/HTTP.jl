@testset "Client.jl" begin
    @testset "GET, HEAD, POST, PUT, DELETE, PATCH: $scheme" for scheme in ["http", "https"]
        @test isok(HTTP.get("$scheme://$httpbin/ip"))
        @test isok(HTTP.head("$scheme://$httpbin/ip"))
        @test HTTP.post("$scheme://$httpbin/patch"; status_exception=false).status == 405
        @test isok(HTTP.post("$scheme://$httpbin/post"; redirect_method=:same))
        @test isok(HTTP.put("$scheme://$httpbin/put"; redirect_method=:same))
        @test isok(HTTP.delete("$scheme://$httpbin/delete"; redirect_method=:same))
        @test isok(HTTP.patch("$scheme://$httpbin/patch"; redirect_method=:same))
    end

    @testset "decompress" begin
        r = HTTP.get("https://$httpbin/gzip")
        @test isok(r)
        @test isascii(String(r.body))
        r = HTTP.get("https://$httpbin/gzip"; decompress=false)
        @test isok(r)
        @test !isascii(String(r.body))
        r = HTTP.get("https://$httpbin/gzip"; decompress=true)
        @test isok(r)
        @test isascii(String(r.body))
    end

    @testset "ASync Client Requests" begin
        @test isok(fetch(Threads.@spawn HTTP.get("https://$httpbin/ip")))
        @test isok(HTTP.get("https://$httpbin/encoding/utf8"))
    end

    @testset "Query to URI" begin
        r = HTTP.get(URI(HTTP.URI("https://$httpbin/response-headers"); query=Dict("hey"=>"dude")))
        h = Dict(r.headers)
        @test (haskey(h, "Hey") ? h["Hey"] == "dude" : h["hey"] == "dude")
    end

    @testset "Cookie Requests" begin
        empty!(HTTP.COOKIEJAR)
        url = "https://$httpbin/cookies"
        r = HTTP.get(url, cookies=true)
        @test String(r.body) == "{}"
        cookies = HTTP.Cookies.getcookies!(HTTP.COOKIEJAR, "https", httpbin, "/cookies")
        @test isempty(cookies)

        url = "https://$httpbin/cookies/set?hey=sailor&foo=bar"
        r = HTTP.get(url, cookies=true)
        @test isok(r)
        @test String(r.body) == "{\"foo\":\"bar\",\"hey\":\"sailor\"}"
        cookies = HTTP.Cookies.getcookies!(HTTP.COOKIEJAR, "https", httpbin, "/cookies")
        @test length(cookies) == 2

        url = "https://$httpbin/cookies/delete?hey"
        r = HTTP.get(url)
        @test isok(r)
        @test String(r.body) == "{\"foo\":\"bar\"}"
        cookies = HTTP.Cookies.getcookies!(HTTP.COOKIEJAR, "https", httpbin, "/cookies")
        @test length(cookies) == 1
    end

    @testset "Client Streaming Test" begin
        r = HTTP.post("https://$httpbin/anything"; body="hey")
        @test isok(r)
        @test contains(String(r.body), "\"data\":\"hey\"")

        r = HTTP.get("https://$httpbin/stream/100")
        @test isok(r)
        x = map(String, split(String(r.body), '\n'; keepempty=false))
        @test length(x) == 100

        io = IOBuffer()
        r = HTTP.get("https://$httpbin/stream/100"; response_body=io)
        @test isok(r)
        x2 = map(String, split(String(take!(io)), '\n'; keepempty=false))
        @test x == x2

        # pass pre-allocated buffer
        body = zeros(UInt8, 100)
        r = HTTP.get("https://$httpbin/bytes/100"; response_body=body)
        @test length(body) == 100
        @test any(x -> x != 0, body)

        # if provided buffer is too small, we won't grow it for user
        body = zeros(UInt8, 10)
        @test_throws BoundsError HTTP.get("https://$httpbin/bytes/100"; response_body=body)

        # also won't shrink it if buffer provided is larger than response body
        body = zeros(UInt8, 10)
        r = HTTP.get("https://$httpbin/bytes/5"; response_body=body)
        @test length(body) == 10
        @test all(x -> x == 0, body[6:end])

        # but if you wrap it in a writable IOBuffer, we will grow it
        io = IOBuffer(body; write=true)
        r = HTTP.get("https://$httpbin/bytes/100"; response_body=io)
        @test length(take!(io)) == 100

        # and you can reuse it
        seekstart(io)
        r = HTTP.get("https://$httpbin/bytes/100"; response_body=io)
        @test length(take!(io)) == 100

        # we respect ptr and size
        body = zeros(UInt8, 100)
        io = IOBuffer(body; write=true, append=true) # size=100, ptr=1
        r = HTTP.get("https://$httpbin/bytes/100"; response_body=io)
        @test length(take!(io)) == 200

        body = zeros(UInt8, 100)
        io = IOBuffer(body, write=true, append=false)
        write(io, body) # size=100, ptr=101
        r = HTTP.get("https://$httpbin/bytes/100"; response_body=io)
        @test length(take!(io)) == 200

        # status error response body handling
        r = HTTP.post("https://$httpbin/status/404"; status_exception=false)
    end

    @testset "Client Body Posting - Vector{UTF8}, String, IOStream, IOBuffer, BufferStream, Dict, NamedTuple" begin
        @test isok(HTTP.post("https://$httpbin/post"; body="hey"))
        @test isok(HTTP.post("https://$httpbin/post"; body=UInt8['h','e','y']))
        io = IOBuffer("hey"); seekstart(io)
        @test isok(HTTP.post("https://$httpbin/post"; body=io))
        mktemp() do path, io
            write(io, "hey"); seekstart(io)
            @test isok(HTTP.post("https://$httpbin/post"; body=io))
        end
        f = Base.BufferStream()
        write(f, "hey")
        close(f)
        @test isok(HTTP.post("https://$httpbin/post"; body=f))
        resp = HTTP.post("https://$httpbin/post"; body=Dict("name" => "value"))
        @test isok(resp)
        # x = JSONBase.materialize(resp.body)
        # @test x["form"] == Dict("name" => ["value"])
        resp = HTTP.post("https://$httpbin/post"; body=(name="value with spaces",))
        @test isok(resp)
        # x = JSONBase.materialize(resp.body)
        # @test x["form"] == Dict("name" => ["value with spaces"])
    end

    @testset "ASync Client Request Body" begin
        f = Base.BufferStream()
        write(f, "hey")
        t = Threads.@spawn HTTP.post("https://$httpbin/post"; body=f)
        #fetch(f) # fetch for the async call to write it's first data
        write(f, " there ") # as we write to f, it triggers another chunk to be sent in our async request
        write(f, "sailor")
        close(f) # setting eof on f causes the async request to send a final chunk and return the response
        r = fetch(t)
        @test isok(r)
        @test contains(String(r.body), "\"data\":\"hey there sailor\"")
    end

    @testset "Client Redirect Following - $read_method" for read_method in ["GET", "HEAD"]
        @test isok(HTTP.request(read_method, "https://$httpbin/redirect/1"))
        @test HTTP.request(read_method, "https://$httpbin/redirect/1", redirect=false, status_exception=false).status == 302
        @test HTTP.request(read_method, "https://$httpbin/redirect/6", status_exception=false).status == 302 #over max number of redirects
        @test isok(HTTP.request(read_method, "https://$httpbin/relative-redirect/1"))
        @test isok(HTTP.request(read_method, "https://$httpbin/absolute-redirect/1"))
        @test isok(HTTP.request(read_method, "https://$httpbin/redirect-to?url=http%3A%2F%2Fgoogle.com"))
    end

    @testset "Client Basic Auth" begin
        @test isok(HTTP.get("https://user:pwd@$httpbin/basic-auth/user/pwd"))
        @test isok(HTTP.get("https://user:pwd@$httpbin/hidden-basic-auth/user/pwd"))
        @test isok(HTTP.get("https://test:%40test@$httpbin/basic-auth/test/%40test"))
        @test isok(HTTP.get("https://$httpbin/basic-auth/user/pwd"; username="user", password="pwd"))
    end

    @testset "Misc" begin
        @test isok(HTTP.post("https://$httpbin/post"; body="√"))
        r = HTTP.request("GET", "https://$httpbin/ip")
        @test isok(r)

        uri = HTTP.URI("https://$httpbin/ip")
        r = HTTP.request("GET", uri)
        @test isok(r)
        r = HTTP.get(uri)
        @test isok(r)

        # ensure we can use AbstractString for requests
        r = HTTP.get(SubString("https://$httpbin/ip",1))
        @test isok(r)

        # Ensure HEAD requests stay the same through redirects by default
        r = HTTP.head("https://$httpbin/redirect/1")
        @test r.request.method == "HEAD"
        @test iszero(length(r.body))
        # But if explicitly requested, GET can be used instead
        r = HTTP.head("https://$httpbin/redirect/1"; redirect_method="GET")
        @test r.request.method == "GET"
        @test length(r.body) > 0
    end

    @testset "readtimeout" begin
        @test_throws CapturedException HTTP.get("http://$httpbin/delay/5"; readtimeout=1, max_retries=0)
        @test isok(HTTP.get("http://$httpbin/delay/1"; readtimeout=2, max_retries=0))
    end

    @testset "Public entry point of HTTP.request and friends (e.g. issue #463)" begin
        headers = Dict("User-Agent" => "HTTP.jl")
        query = Dict("hello" => "world")
        body = UInt8[1, 2, 3]
        for uri in ("https://$httpbin/anything", HTTP.URI("https://$httpbin/anything"))
            # HTTP.request
            @test isok(HTTP.request("GET", uri; headers=headers, body=body, query=query))
            @test isok(HTTP.request("GET", uri, headers; body=body, query=query))
            @test isok(HTTP.request("GET", uri, headers, body; query=query))
            # HTTP.get
            @test isok(HTTP.get(uri; headers=headers, body=body, query=query))
            @test isok(HTTP.get(uri, headers; body=body, query=query))
            @test isok(HTTP.get(uri, headers, body; query=query))
            # HTTP.put
            @test isok(HTTP.put(uri; headers=headers, body=body, query=query))
            @test isok(HTTP.put(uri, headers; body=body, query=query))
            @test isok(HTTP.put(uri, headers, body; query=query))
            # HTTP.post
            @test isok(HTTP.post(uri; headers=headers, body=body, query=query))
            @test isok(HTTP.post(uri, headers; body=body, query=query))
            @test isok(HTTP.post(uri, headers, body; query=query))
            # HTTP.patch
            @test isok(HTTP.patch(uri; headers=headers, body=body, query=query))
            @test isok(HTTP.patch(uri, headers; body=body, query=query))
            @test isok(HTTP.patch(uri, headers, body; query=query))
            # HTTP.delete
            @test isok(HTTP.delete(uri; headers=headers, body=body, query=query))
            @test isok(HTTP.delete(uri, headers; body=body, query=query))
            @test isok(HTTP.delete(uri, headers, body; query=query))
        end
    end
end