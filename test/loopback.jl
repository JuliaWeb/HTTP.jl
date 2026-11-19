using Test
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

HTTP.ConnectionPool.tcpstatus(c::HTTP.ConnectionPool.Connection{Loopback}) = "🤖 "


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
        elseif (m = match(r"^/delay([0-9]*)$", req.uri)) != nothing
            t = parse(Int, first(m.captures))
            sleep(t/10)
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

function HTTP.ConnectionPool.getconnection(::Type{Loopback},
                                           host::AbstractString,
                                           port::AbstractString;
                                           kw...)::Loopback
    return Loopback()
end

config = [
    :socket_type => Loopback,
    :retry => false,
    :connection_limit => 1
]

lbreq(req, headers, body; method="GET", kw...) =
      HTTP.request(method, "http://test/$req", headers, body; config..., kw...)

lbopen(f, req, headers) =
    HTTP.open(f, "PUT", "http://test/$req", headers; config...)

@testset "loopback" begin

    global server_events

    r = lbreq("echo", [], ["Hello", IOBuffer(" "), "World!"]);
    @test String(r.body) == "Hello World!"

    io = FunctionIO(()->"Hello World!")
    @test String(read(io)) == "Hello World!"

    r = lbreq("echo", [], FunctionIO(()->"Hello World!"))
    @test String(r.body) == "Hello World!"

    r = lbreq("echo", [], ["Hello", " ", "World!"]);
    @test String(r.body) == "Hello World!"

    r = lbreq("echo", [], [Vector{UInt8}("Hello"),
                         Vector{UInt8}(" "),
                         Vector{UInt8}("World!")]);
    @test String(r.body) == "Hello World!"

    r = lbreq("delay10", [], [Vector{UInt8}("Hello"),
                              Vector{UInt8}(" "),
                              Vector{UInt8}("World!")]);
    @test String(r.body) == "Hello World!"

    HTTP.ConnectionPool.showpool(STDOUT)

    body = nothing
    body_sent = false
    r = lbopen("delay10", []) do http
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



    # "If [the response] indicates the server does not wish to receive the
    #  message body and is closing the connection, the client SHOULD
    #  immediately cease transmitting the body and close the connection."
    # https://tools.ietf.org/html/rfc7230#section-6.5

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

    r = lbreq("echo", [], [
        FunctionIO(()->(sleep(0.1); "Hello")),
        FunctionIO(()->(sleep(0.1); " World!"))])
    @test String(r.body) == "Hello World!"

    hello_sent = false
    world_sent = false
    @test_throws HTTP.StatusError begin
        r = lbreq("abort", [], [
            FunctionIO(()->(hello_sent = true; sleep(0.1); "Hello")),
            FunctionIO(()->(world_sent = true; " World!"))])
    end
    @test hello_sent
    @test !world_sent

    HTTP.ConnectionPool.showpool(STDOUT)

    function async_test(m=["GET","GET","GET","GET","GET"];kw...)
        r1 = nothing
        r2 = nothing
        r3 = nothing
        r4 = nothing
        r5 = nothing
        t1 = time()
        @sync begin
            @async r1 = lbreq("delay1", [], FunctionIO(()->(sleep(0.00); "Hello World! 1"));
                              method=m[1], kw...)
            @async r2 = lbreq("delay2", [],
                              FunctionIO(()->(sleep(0.01); "Hello World! 2"));
                              method=m[2], kw...)
            @async r3 = lbreq("delay3", [],
                              FunctionIO(()->(sleep(0.02); "Hello World! 3"));
                              method=m[3], kw...)
            @async r4 = lbreq("delay4", [],
                              FunctionIO(()->(sleep(0.03); "Hello World! 4"));
                              method=m[4], kw...)
            @async r5 = lbreq("delay5", [],
                              FunctionIO(()->(sleep(0.04); "Hello World! 5"));
                              method=m[5], kw...)
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
    @show t
    @test 2.1 < t < 2.3
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
    @show t
    @test 0.9 < t < 1.1
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
    @show t
    @test 0.6 < t < 1
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
    @show t
    @test 0.5 < t < 0.8
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
    @show t
    @test 0.5 < t < 0.8
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


    # "A user agent SHOULD NOT pipeline requests after a
    #  non-idempotent method, until the final response
    #  status code for that method has been received"
    # https://tools.ietf.org/html/rfc7230#section-6.3.2

    server_events = []
    t = async_test(["POST","GET","GET","GET","GET"])
    @test server_events == [
        "Request: POST /delay1 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (POST /delay1 HTTP/1.1)",
        "Request: GET /delay2 HTTP/1.1",
        "Request: GET /delay3 HTTP/1.1",
        "Request: GET /delay4 HTTP/1.1",
        "Request: GET /delay5 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay2 HTTP/1.1)",
        "Response: HTTP/1.1 200 OK <= (GET /delay3 HTTP/1.1)",
        "Response: HTTP/1.1 200 OK <= (GET /delay4 HTTP/1.1)",
        "Response: HTTP/1.1 200 OK <= (GET /delay5 HTTP/1.1)"]

    server_events = []
    t = async_test(["GET","GET","POST", "GET","GET"])
    @test server_events == [
        "Request: GET /delay1 HTTP/1.1",
        "Request: GET /delay2 HTTP/1.1",
        "Request: POST /delay3 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay1 HTTP/1.1)",
        "Response: HTTP/1.1 200 OK <= (GET /delay2 HTTP/1.1)",
        "Response: HTTP/1.1 200 OK <= (POST /delay3 HTTP/1.1)",
        "Request: GET /delay4 HTTP/1.1",
        "Request: GET /delay5 HTTP/1.1",
        "Response: HTTP/1.1 200 OK <= (GET /delay4 HTTP/1.1)",
        "Response: HTTP/1.1 200 OK <= (GET /delay5 HTTP/1.1)"]

    HTTP.ConnectionPool.closeall()
end
