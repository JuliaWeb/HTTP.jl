@testset "Client.jl" begin
    isok(r) = r.status == 200
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
        @test isok(fetch(@async HTTP.get("https://$httpbin/ip")))
        @test isok(HTTP.get("https://$httpbin/encoding/utf8"))
    end

    @testset "Query to URI" begin
        r = HTTP.get(URI(HTTP.URI("https://$httpbin/response-headers"); query=Dict("hey"=>"dude")))
        h = Dict(r.headers)
        @test (haskey(h, "Hey") ? h["Hey"] == "dude" : h["hey"] == "dude")
    end

    # @testset "Cookie Requests" begin
    #     empty!(HTTP.COOKIEJAR)
    #     url = "https://$httpbin/cookies"
    #     r = HTTP.get(url, cookies=true)
    #     @test String(r.body) == "{}"
    #     cookies = HTTP.Cookies.getcookies!(HTTP.COOKIEJAR, URI(url))
    #     @test isempty(cookies)

    #     url = "https://$httpbin/cookies/set?hey=sailor&foo=bar"
    #     r = HTTP.get(url, cookies=true)
    #     @test isok(r)
    #     cookies = HTTP.Cookies.getcookies!(HTTP.COOKIEJAR, URI(url))
    #     @test length(cookies) == 2

    #     url = "https://$httpbin/cookies/delete?hey"
    #     r = HTTP.get(url)
    #     cookies = HTTP.Cookies.getcookies!(HTTP.COOKIEJAR, URI(url))
    #     @test length(cookies) == 1
    # end

    @testset "Client Streaming Test" begin
        r = HTTP.post("https://$httpbin/post"; body="hey")
        @test isok(r)
        # @test JSONBase.materialize(r.body)["data"] == "hey"

        r = HTTP.get("https://$httpbin/stream/100")
        @test isok(r)

        # x = JSONBase.materialize(r.body; jsonlines=true);

        io = IOBuffer()
        r = HTTP.get("https://$httpbin/stream/100"; response_body=io)
        seekstart(io)
        @test isok(r)

        # x2 = JSONBase.materialize(io; jsonlines=true);
        # @test x == x2

        # pass pre-allocated buffer
        body = zeros(UInt8, 100)
        r = HTTP.get("https://$httpbin/bytes/100"; response_body=body)
        @test body === r.body

        # wrapping pre-allocated buffer in IOBuffer will write to buffer directly
        io = IOBuffer(body; write=true)
        r = HTTP.get("https://$httpbin/bytes/100"; response_body=io)
        @test body === r.body.data

        # if provided buffer is too small, we won't grow it for user
        body = zeros(UInt8, 10)
        @test_throws CapturedException HTTP.get("https://$httpbin/bytes/100"; response_body=body)

        # also won't shrink it if buffer provided is larger than response body
        body = zeros(UInt8, 10)
        r = HTTP.get("https://$httpbin/bytes/5"; response_body=body)
        @test body === r.body
        @test length(body) == 10
        @test HTTP.getheader(r.headers, "Content-Length") == "5"

        # but if you wrap it in a writable IOBuffer, we will grow it
        io = IOBuffer(body; write=true)
        r = HTTP.get("https://$httpbin/bytes/100"; response_body=io)
        # same Array, though it was resized larger
        @test body === r.body.data
        @test length(body) == 100

        # and you can reuse it
        seekstart(io)
        r = HTTP.get("https://$httpbin/bytes/100"; response_body=io)
        # same Array, though it was resized larger
        @test body === r.body.data
        @test length(body) == 100

        # we respect ptr and size
        body = zeros(UInt8, 100)
        io = IOBuffer(body; write=true, append=true) # size=100, ptr=1
        r = HTTP.get("https://$httpbin/bytes/100"; response_body=io)
        @test length(body) == 200

        body = zeros(UInt8, 100)
        io = IOBuffer(body, write=true, append=false)
        write(io, body) # size=100, ptr=101
        r = HTTP.get("https://$httpbin/bytes/100"; response_body=io)
        @test length(body) == 200
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
        t = @async HTTP.post("https://$httpbin/post"; body=f)
        #fetch(f) # fetch for the async call to write it's first data
        write(f, " there ") # as we write to f, it triggers another chunk to be sent in our async request
        write(f, "sailor")
        close(f) # setting eof on f causes the async request to send a final chunk and return the response
        @test isok(fetch(t))
    end

    @testset "Client Redirect Following - $read_method" for read_method in ["GET", "HEAD"]
        @test isok(HTTP.request(read_method, "https://$httpbin/redirect/1"))
        @test HTTP.request(read_method, "https://$httpbin/redirect/1", redirect=false, status_exception=false).status == 302
        @test HTTP.request(read_method, "https://$httpbin/redirect/6", status_exception=false).status == 302 #over max number of redirects
        @test isok(HTTP.request(read_method, "https://$httpbin/relative-redirect/1"))
        @test isok(HTTP.request(read_method, "https://$httpbin/absolute-redirect/1"))
        @test isok(HTTP.request(read_method, "https://$httpbin/redirect-to?url=http%3A%2F%2Fgoogle.com"))
    end

    # @testset "Client Basic Auth" begin
    #     @test isok(HTTP.get("https://user:pwd@$httpbin/basic-auth/user/pwd"))
    #     @test isok(HTTP.get("https://user:pwd@$httpbin/hidden-basic-auth/user/pwd"))
    #     @test isok(HTTP.get("https://test:%40test@$httpbin/basic-auth/test/%40test"))
    # end

    # @testset "Misc" begin
    #     @test isok(HTTP.post("https://$httpbin/post"; body="√"))
    #     r = HTTP.request("GET", "https://$httpbin/ip")
    #     @test isok(r)

    #     uri = HTTP.URI("https://$httpbin/ip")
    #     r = HTTP.request("GET", uri)
    #     @test isok(r)
    #     r = HTTP.get(uri)
    #     @test isok(r)

    #     r = HTTP.request("GET", "https://$httpbin/ip")
    #     @test isok(r)

    #     uri = HTTP.URI("https://$httpbin/ip")
    #     r = HTTP.request("GET", uri)
    #     @test isok(r)

    #     r = HTTP.get("https://$httpbin/image/png")
    #     @test isok(r)

    #     # ensure we can use AbstractString for requests
    #     r = HTTP.get(SubString("https://$httpbin/ip",1))

    #     # canonicalizeheaders
    #     @test isok(HTTP.get("https://$httpbin/ip"; canonicalizeheaders=false))

    #     # Ensure HEAD requests stay the same through redirects by default
    #     r = HTTP.head("https://$httpbin/redirect/1")
    #     @test r.request.method == "HEAD"
    #     @test iszero(length(r.body))
    #     # But if explicitly requested, GET can be used instead
    #     r = HTTP.head("https://$httpbin/redirect/1"; redirect_method="GET")
    #     @test r.request.method == "GET"
    #     @test length(r.body) > 0
    # end
end