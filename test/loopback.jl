using HTTP

using HTTP.IOExtras
using HTTP.Parsers
using HTTP.Messages
using HTTP.MessageRequest.bodylength
using HTTP.Parsers.escapelines


mutable struct FunctionIO <: IO
    f::Function
    buf::IOBuffer
    done::Bool
end

FunctionIO(f::Function) = FunctionIO(f, IOBuffer(), false)
call(fio::FunctionIO) = !fio.done &&
                        (fio.buf = IOBuffer(fio.f()) ; fio.done = true)
Base.eof(fio::FunctionIO) = (call(fio); eof(fio.buf))
Base.nb_available(fio::FunctionIO) = (call(fio); nb_available(fio.buf))
Base.readavailable(fio::FunctionIO) = (call(fio); readavailable(fio.buf))
Base.read(fio::FunctionIO, a...) = (call(fio); read(fio.buf, a...))


mutable struct Loopback <: IO
    got_headers::Bool
    buf::IOBuffer
    io::BufferStream
end
Loopback() = Loopback(false, IOBuffer(), BufferStream())

function reset(lb::Loopback)
    truncate(lb.buf, 0)
    lb.got_headers = false
end

Base.eof(lb::Loopback) = eof(lb.io)
Base.nb_available(lb::Loopback) = nb_available(lb.io)
Base.readavailable(lb::Loopback) = readavailable(lb.io)
Base.close(lb::Loopback) = (close(lb.io); close(lb.buf))
Base.isopen(lb::Loopback) = isopen(lb.io)


server_events = []

function on_headers(f, lb)
    if lb.got_headers
        return
    end
    buf = copy(lb.buf)
    seek(buf, 0)
    req = Request()
    try
        readheaders(buf, Parser(), req)
        lb.got_headers = true
    catch e
        if !(e isa EOFError || e isa HTTP.ParsingError)
            rethrow(e)
        end
    end
    if lb.got_headers
            f(req)
    end
end

function on_body(f, lb)
    s = String(take!(copy(lb.buf)))
#    println("Request: \"\"\"")
#    println(escapelines(s))
#    println("\"\"\"")
    req = nothing
    try
        req = parse(HTTP.Request, s)
    catch e
        if !(e isa EOFError || e isa HTTP.ParsingError)
            rethrow(e)
        end
    end
    if req != nothing
        reset(lb)
        @schedule try
            f(req)
        catch e
            println("⚠️ on_body exception: $e")
        end
    end
end


function Base.unsafe_write(lb::Loopback, p::Ptr{UInt8}, n::UInt)

    global server_events

    if !isopen(lb.buf)
        throw(ArgumentError("stream is closed or unusable"))
    end

    n = unsafe_write(lb.buf, p, n)

    on_headers(lb) do req

        println("📡  $(sprint(showcompact, req))")
        push!(server_events, "Request: $(sprint(showcompact, req))")

        if req.uri == "/abort"
            reset(lb)
            response = HTTP.Response(403, ["Connection" => "close",
                                          "Content-Length" => 0]; request=req)
            push!(server_events, "Response: $(sprint(showcompact, response))")
            write(lb.io, response)
        end
    end

    on_body(lb) do req

        l = length(req.body)
        response = HTTP.Response(200, ["Content-Length" => l],
                                      body = req.body; request=req)
        if req.uri == "/echo"
            push!(server_events, "Response: $(sprint(showcompact, response))")
            write(lb.io, response)
        elseif ismatch(r"^/delay", req.uri)
            sleep(1)
            push!(server_events, "Response: $(sprint(showcompact, response))")
            write(lb.io, response)
        else
            response = HTTP.Response(403,
                                     ["Connection" => "close",
                                      "Content-Length" => 0]; request=req)
            push!(server_events, "Response: $(sprint(showcompact, response))")
            write(lb.io, response)
        end
    end

    return n
end

HTTP.IOExtras.tcpsocket(::Loopback) = TCPSocket()

function HTTP.Connect.getconnection(::Type{Loopback},
                                    host::AbstractString,
                                    port::AbstractString;
                                    kw...)::Loopback
    return Loopback()
end

config = [
    :socket_type => Loopback,
    :retry => false,
    :duplicate_limit => 0
]

lbget(req, headers, body; kw...) =
      HTTP.request("GET", "http://test/$req", headers, body; config..., kw...)

lbopen(f, req, headers) =
    HTTP.open(f, "GET", "http://test/$req", headers; config...)

@testset "loopback" begin

    global server_events

    r = lbget("echo", [], ["Hello", IOBuffer(" "), "World!"]);
    @test String(r.body) == "Hello World!"

    io = FunctionIO(()->"Hello World!")
    @test String(read(io)) == "Hello World!"

    r = lbget("echo", [], FunctionIO(()->"Hello World!"))
    @test String(r.body) == "Hello World!"

    r = lbget("echo", [], ["Hello", " ", "World!"]);
    @test String(r.body) == "Hello World!"

    r = lbget("echo", [], [Vector{UInt8}("Hello"),
                         Vector{UInt8}(" "),
                         Vector{UInt8}("World!")]);
    @test String(r.body) == "Hello World!"

    r = lbget("delay", [], [Vector{UInt8}("Hello"),
                         Vector{UInt8}(" "),
                         Vector{UInt8}("World!")]);
    @test String(r.body) == "Hello World!"

    HTTP.ConnectionPool.showpool(STDOUT)

    body = nothing
    body_sent = false
    r = lbopen("delay", []) do http
        @sync begin
            @async begin
                write(http, "Hello World!")
                closewrite(http)
                body_sent = true
            end
            startread(http)
            body = read(http)
            closeread(http)
        end
    end
    @test String(body) == "Hello World!"

    body = nothing
    body_aborted = false
    body_sent = false
    @test_throws HTTP.StatusError begin
        r = lbopen("abort", []) do http
            @sync begin
                @async try
                    sleep(0.1)
                    write(http, "Hello World!")
                    closewrite(http)
                    body_sent = true
                catch e
                    if e isa ArgumentError &&
                        e.msg == "stream is closed or unusable"
                        body_aborted = true
                    else
                        rethrow(e)
                    end
                end
                startread(http)
                body = read(http)
                closeread(http)
            end
        end
    end
    @test body_aborted == true
    @test body_sent == false

    r = lbget("echo", [], [
        FunctionIO(()->(sleep(0.1); "Hello")),
        FunctionIO(()->(sleep(0.1); " World!"))])
    @test String(r.body) == "Hello World!"

    hello_sent = false
    world_sent = false
    @test_throws HTTP.StatusError begin
        r = lbget("abort", [], [
            FunctionIO(()->(hello_sent = true; sleep(0.1); "Hello")),
            FunctionIO(()->(world_sent = true; " World!"))])
    end
    @test hello_sent
    @test !world_sent

    HTTP.ConnectionPool.showpool(STDOUT)

    function async_test(;kw...)
        r1 = nothing
        r2 = nothing
        r3 = nothing
        r4 = nothing
        r5 = nothing
        t1 = time()
        @sync begin
            @async r1 = lbget("delay1", [], "Hello World! 1"; kw...)
            sleep(0.01)
            @async r2 = lbget("delay2", [], "Hello World! 2"; kw...)
            sleep(0.01)
            @async r3 = lbget("delay3", [], "Hello World! 3"; kw...)
            sleep(0.01)
            @async r4 = lbget("delay4", [], "Hello World! 4"; kw...)
            sleep(0.01)
            @async r5 = lbget("delay5", [], "Hello World! 5"; kw...)
        end
        t2 = time()

        @test String(r1.body) == "Hello World! 1"
        @test String(r2.body) == "Hello World! 2"
        @test String(r3.body) == "Hello World! 3"
        @test String(r4.body) == "Hello World! 4"
        @test String(r5.body) == "Hello World! 5"

        return t2 - t1
    end


    server_events = []
    t = async_test(;pipeline_limit=0)
    @test 4 < t < 6
    @test server_events == [
        "Request: GET /delay1 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay1 HTTP/1.1)",
        "Request: GET /delay2 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay2 HTTP/1.1)",
        "Request: GET /delay3 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay3 HTTP/1.1)",
        "Request: GET /delay4 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay4 HTTP/1.1)",
        "Request: GET /delay5 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay5 HTTP/1.1)"]

    server_events = []
    t = async_test(;pipeline_limit=1)
    @test 2 < t < 4
    @test server_events == [
        "Request: GET /delay1 HTTP/1.1",
        "Request: GET /delay2 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay1 HTTP/1.1)",
        "Request: GET /delay3 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay2 HTTP/1.1)",
        "Request: GET /delay4 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay3 HTTP/1.1)",
        "Request: GET /delay5 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay4 HTTP/1.1)",
        "Response: HTTP/1.1 200 OK <= (GET /delay5 HTTP/1.1)"]

    server_events = []
    t = async_test(;pipeline_limit=2)
    @test 1 < t < 3
    @test server_events == [
        "Request: GET /delay1 HTTP/1.1",
        "Request: GET /delay2 HTTP/1.1",
        "Request: GET /delay3 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay1 HTTP/1.1)",
        "Request: GET /delay4 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay2 HTTP/1.1)",
        "Request: GET /delay5 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay3 HTTP/1.1)",
        "Response: HTTP/1.1 200 OK <= (GET /delay4 HTTP/1.1)",
        "Response: HTTP/1.1 200 OK <= (GET /delay5 HTTP/1.1)"]

    server_events = []
    t = async_test(;pipeline_limit=3)
    @test 1 < t < 3
    @test server_events == [
        "Request: GET /delay1 HTTP/1.1",
        "Request: GET /delay2 HTTP/1.1",
        "Request: GET /delay3 HTTP/1.1",
        "Request: GET /delay4 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay1 HTTP/1.1)",
        "Request: GET /delay5 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay2 HTTP/1.1)",
        "Response: HTTP/1.1 200 OK <= (GET /delay3 HTTP/1.1)",
        "Response: HTTP/1.1 200 OK <= (GET /delay4 HTTP/1.1)",
        "Response: HTTP/1.1 200 OK <= (GET /delay5 HTTP/1.1)"]

    server_events = []
    t = async_test()
    @test 1 < t < 2
    @test server_events == [
        "Request: GET /delay1 HTTP/1.1",
        "Request: GET /delay2 HTTP/1.1",
        "Request: GET /delay3 HTTP/1.1",
        "Request: GET /delay4 HTTP/1.1",
        "Request: GET /delay5 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay1 HTTP/1.1)",
        "Response: HTTP/1.1 200 OK <= (GET /delay2 HTTP/1.1)",
        "Response: HTTP/1.1 200 OK <= (GET /delay3 HTTP/1.1)",
        "Response: HTTP/1.1 200 OK <= (GET /delay4 HTTP/1.1)",
        "Response: HTTP/1.1 200 OK <= (GET /delay5 HTTP/1.1)"]
end


