@testset "HTTP.Client" begin

@testset "HTTP.Connection" begin
    conn = HTTP.Connection(IOBuffer())
    @test conn.state == HTTP.Busy
    HTTP.idle!(conn)
    @test conn.state == HTTP.Idle
    HTTP.busy!(conn)
    @test conn.state == HTTP.Busy
    HTTP.dead!(conn)
    @test conn.state == HTTP.Dead
    HTTP.idle!(conn)
    @test conn.state == HTTP.Dead
    HTTP.busy!(conn)
    @test conn.state == HTTP.Dead
end

for sch in ("http", "https")
    println("running $sch client tests...")

    println("simple GET, HEAD, POST, DELETE, etc.")
    @test HTTP.status(HTTP.get("$sch://httpbin.org/ip")) == 200
    @test HTTP.status(HTTP.head("$sch://httpbin.org/ip")) == 200
    @test HTTP.status(HTTP.options("$sch://httpbin.org/ip")) == 200
    @test HTTP.status(HTTP.post("$sch://httpbin.org/ip"; statusraise=false)) == 405
    @test HTTP.status(HTTP.post("$sch://httpbin.org/post")) == 200
    @test HTTP.status(HTTP.put("$sch://httpbin.org/put")) == 200
    @test HTTP.status(HTTP.delete("$sch://httpbin.org/delete")) == 200
    @test HTTP.status(HTTP.patch("$sch://httpbin.org/patch")) == 200

    # Testing within tasks, see https://github.com/JuliaWeb/HTTP.jl/issues/18
    println("async client request")
    @test HTTP.status(wait(@schedule HTTP.get("$sch://httpbin.org/ip"))) == 200

    @test HTTP.status(HTTP.get("$sch://httpbin.org/encoding/utf8")) == 200

    println("pass query to uri")
    r = HTTP.get("$sch://httpbin.org/response-headers"; query=Dict("hey"=>"dude"))
    h = HTTP.headers(r)
    @test (haskey(h, "Hey") ? h["Hey"] == "dude" : h["hey"] == "dude")

    println("cookie requests")
    empty!(HTTP.DEFAULT_CLIENT.cookies)
    r = HTTP.get("$sch://httpbin.org/cookies")
    body = String(take!(r))
    @test body == "{\n  \"cookies\": {}\n}\n"
    r = HTTP.get("$sch://httpbin.org/cookies/set?hey=sailor&foo=bar")
    @test HTTP.status(r) == 200
    body = String(take!(r))
    @test body == "{\n  \"cookies\": {\n    \"foo\": \"bar\", \n    \"hey\": \"sailor\"\n  }\n}\n"

    # r = HTTP.get("$sch://httpbin.org/cookies/delete?hey")
    # @test String(take!(r)) == "{\n  \"cookies\": {\n    \"hey\": \"\"\n  }\n}\n"

    # stream
    println("client streaming tests")
    r = HTTP.post("$sch://httpbin.org/post"; body="hey")
    @test HTTP.status(r) == 200
    # stream, but body is too small to actually stream
    r = HTTP.post("$sch://httpbin.org/post"; body="hey", stream=true)
    @test HTTP.status(r) == 200
    r = HTTP.get("$sch://httpbin.org/stream/100")
    @test HTTP.status(r) == 200
    totallen = length(HTTP.body(r)) # number of bytes to expect
    bytes = take!(r)
    begin
        r = HTTP.get("$sch://httpbin.org/stream/100"; stream=true)
        @test HTTP.status(r) == 200
        len = length(HTTP.body(r))
        HTTP.@timeout 15.0 begin
            while !eof(HTTP.body(r))
                b = take!(r)
            end
        end throw(error("timed out"))
    end

    # body posting: Vector{UInt8}, String, IOStream, IOBuffer, FIFOBuffer
    println("client body posting of various types")
    @test HTTP.status(HTTP.post("$sch://httpbin.org/post"; body="hey")) == 200
    @test HTTP.status(HTTP.post("$sch://httpbin.org/post"; body=UInt8['h','e','y'])) == 200
    io = IOBuffer("hey"); seekstart(io)
    @test HTTP.status(HTTP.post("$sch://httpbin.org/post"; body=io)) == 200
    tmp = tempname()
    open(f->write(f, "hey"), tmp, "w")
    io = open(tmp)
    @test HTTP.status(HTTP.post("$sch://httpbin.org/post"; body=io)) == 200
    close(io); rm(tmp)
    f = HTTP.FIFOBuffer("hey")
    @test HTTP.status(HTTP.post("$sch://httpbin.org/post"; body=f)) == 200

    # chunksize
    println("client transfer-encoding chunked")
    @test_broken HTTP.status(HTTP.post("$sch://httpbin.org/post"; body="hey", chunksize=2)) == 200
    @test_broken HTTP.status(HTTP.post("$sch://httpbin.org/post"; body=UInt8['h','e','y'], chunksize=2)) == 200
    io = IOBuffer("hey"); seekstart(io)
    @test_broken HTTP.status(HTTP.post("$sch://httpbin.org/post"; body=io, chunksize=2)) == 200
    tmp = tempname()
    open(f->write(f, "hey"), tmp, "w")
    io = open(tmp)
    @test_broken HTTP.status(HTTP.post("$sch://httpbin.org/post"; body=io, chunksize=2)) == 200
    close(io); rm(tmp)
    f = HTTP.FIFOBuffer("hey")
    @test_broken HTTP.status(HTTP.post("$sch://httpbin.org/post"; body=f, chunksize=2)) == 200

    # multipart
    println("client multipart body")
    r = HTTP.post("$sch://httpbin.org/post"; body=Dict("hey"=>"there"))
    @test HTTP.status(r) == 200
    @test startswith(String(take!(r)), "{\n  \"args\": {}, \n  \"data\": \"\", \n  \"files\": {}, \n  \"form\": {\n    \"hey\": \"there\"\n  }")

    r = HTTP.post("$sch://httpbin.org/post"; body=Dict("hey"=>"there"), chunksize=1000)
    @test HTTP.status(r) == 200
    @test startswith(String(take!(r)), "{\n  \"args\": {}, \n  \"data\": \"\", \n  \"files\": {}, \n  \"form\": {\n    \"hey\": \"there\"\n  }")

    tmp = tempname()
    open(f->write(f, "hey"), tmp, "w")
    io = open(tmp)
    r = HTTP.post("$sch://httpbin.org/post"; body=Dict("hey"=>"there", "iostream"=>io))
    close(io); rm(tmp)
    @test HTTP.status(r) == 200
    str = String(take!(r))
    @test startswith(str, "{\n  \"args\": {}, \n  \"data\": \"\", \n  \"files\": {\n    \"iostream\": \"hey\"\n  }, \n  \"form\": {\n    \"hey\": \"there\"\n  }")

    tmp = tempname()
    open(f->write(f, "hey"), tmp, "w")
    io = open(tmp)
    r = HTTP.post("$sch://httpbin.org/post"; body=Dict("hey"=>"there", "iostream"=>io), chunksize=1000)
    close(io); rm(tmp)
    @test HTTP.status(r) == 200
    @test startswith(String(take!(r)), "{\n  \"args\": {}, \n  \"data\": \"\", \n  \"files\": {\n    \"iostream\": \"hey\"\n  }, \n  \"form\": {\n    \"hey\": \"there\"\n  }")

    tmp = tempname()
    open(f->write(f, "hey"), tmp, "w")
    io = open(tmp)
    m = HTTP.Multipart("mycoolfile.txt", io)
    r = HTTP.post("$sch://httpbin.org/post"; body=Dict("hey"=>"there", "multi"=>m))
    close(io); rm(tmp)
    @test HTTP.status(r) == 200
    @test startswith(String(take!(r)), "{\n  \"args\": {}, \n  \"data\": \"\", \n  \"files\": {\n    \"multi\": \"hey\"\n  }, \n  \"form\": {\n    \"hey\": \"there\"\n  }")

    tmp = tempname()
    open(f->write(f, "hey"), tmp, "w")
    io = open(tmp)
    m = HTTP.Multipart("mycoolfile", io, "application/octet-stream")
    r = HTTP.post("$sch://httpbin.org/post"; body=Dict("hey"=>"there", "multi"=>m), chunksize=1000)
    close(io); rm(tmp)
    @test HTTP.status(r) == 200
    @test startswith(String(take!(r)), "{\n  \"args\": {}, \n  \"data\": \"\", \n  \"files\": {\n    \"multi\": \"hey\"\n  }, \n  \"form\": {\n    \"hey\": \"there\"\n  }")

    # asynchronous
    println("asynchronous client request body")
    begin
        f = HTTP.FIFOBuffer()
        write(f, "hey")
        t = @async HTTP.post("$sch://httpbin.org/post"; body=f)
        wait(f) # wait for the async call to write it's first data
        write(f, " there ") # as we write to f, it triggers another chunk to be sent in our async request
        write(f, "sailor")
        close(f) # setting eof on f causes the async request to send a final chunk and return the response
        @test HTTP.status(wait(t)) == 200
    end

    # redirects
    println("client redirect following")
    r = HTTP.get("$sch://httpbin.org/redirect/1")
    @test HTTP.status(r) == 200
    @test length(HTTP.history(r)) == 1
    @test_throws HTTP.RedirectError HTTP.get("$sch://httpbin.org/redirect/6")
    @test HTTP.status(HTTP.get("$sch://httpbin.org/relative-redirect/1")) == 200
    @test HTTP.status(HTTP.get("$sch://httpbin.org/absolute-redirect/1")) == 200
    @test HTTP.status(HTTP.get("$sch://httpbin.org/redirect-to?url=http%3A%2F%2Fexample.com")) == 200

    @test HTTP.status(HTTP.post("$sch://httpbin.org/post"; body="√")) == 200
    println("client basic auth")
    @test HTTP.status(HTTP.get("$sch://user:pwd@httpbin.org/basic-auth/user/pwd")) == 200
    @test HTTP.status(HTTP.get("$sch://user:pwd@httpbin.org/hidden-basic-auth/user/pwd")) == 200

    # custom client & other high-level entries
    println("high-level client request methods")
    buf = IOBuffer()
    cli = HTTP.Client(buf)
    HTTP.get(cli, "$sch://httpbin.org/ip")
    seekstart(buf)
    @test length(String(take!(buf))) > 0

    r = HTTP.request("$sch://httpbin.org/ip")
    @test HTTP.status(r) == 200

    uri = HTTP.URI("$sch://httpbin.org/ip")
    r = HTTP.request(uri)
    @test HTTP.status(r) == 200
    r = HTTP.get(uri)
    @test HTTP.status(r) == 200
    r = HTTP.get(cli, uri)
    @test HTTP.status(r) == 200

    r = HTTP.request(HTTP.GET, "$sch://httpbin.org/ip")
    @test HTTP.status(r) == 200

    uri = HTTP.URI("$sch://httpbin.org/ip")
    r = HTTP.request("GET", uri)
    @test HTTP.status(r) == 200

    req = HTTP.Request(HTTP.GET, uri, HTTP.Headers(), HTTP.FIFOBuffer())
    r = HTTP.request(req)
    @test HTTP.status(r) == 200
    @test !HTTP.isnull(HTTP.request(r))
    @test length(take!(r)) > 0

    for c in HTTP.DEFAULT_CLIENT.httppool["httpbin.org"]
        HTTP.dead!(c)
    end

    r = HTTP.get(cli, "$sch://httpbin.org/ip")
    @test isempty(HTTP.cookies(r))
    @test isempty(HTTP.history(r))

    r = HTTP.get("$sch://httpbin.org/image/png")
    @test HTTP.status(r) == 200

    # ensure we can use AbstractString for requests
    r = HTTP.get(SubString("http://httpbin.org/ip",1))

    # canonicalizeheaders
    @test HTTP.status(HTTP.get("$sch://httpbin.org/ip"; canonicalizeheaders=false)) == 200

    # r = HTTP.connect("http://47.89.41.164:80")
    # gzip body = "hey"
    # body = UInt8[0x1f,0x8b,0x08,0x00,0x00,0x00,0x00,0x00,0x00,0x03,0xcb,0x48,0xad,0x04,0x00,0xf0,0x15,0xd6,0x88,0x03,0x00,0x00,0x00]
    # r = HTTP.post("$sch://httpbin.org/post"; body=body, chunksize=1)
end

end # @testset "HTTP.Client"
