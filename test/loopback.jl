module TestLoopback

using Test
using HTTP
using HTTP.IOExtras
using HTTP.Parsers
using HTTP.Messages
using HTTP.Sockets
import ..httpbin

mutable struct FunctionIO <: IO
    f::Function
    buf::IOBuffer
    done::Bool
end
FunctionIO(f::Function) = FunctionIO(f, IOBuffer(), false)

mutable struct Loopback <: IO
    got_headers::Bool
    buf::IOBuffer
    io::Base.BufferStream
end
Loopback() = Loopback(false, IOBuffer(), Base.BufferStream())

pool = HTTP.Pool(1)

config = [
    :socket_type => Loopback,
    :retry => false,
    :pool => pool,
]

server_events = []

call(fio::FunctionIO) = !fio.done && (fio.buf = IOBuffer(fio.f()) ; fio.done = true)

Base.bytesavailable(fio::FunctionIO) = (call(fio); bytesavailable(fio.buf))
Base.bytesavailable(lb::Loopback) = bytesavailable(lb.io)
Base.close(lb::Loopback) = (close(lb.io); close(lb.buf))
Base.eof(fio::FunctionIO) = (call(fio); eof(fio.buf))
Base.eof(lb::Loopback) = eof(lb.io)
Base.isopen(lb::Loopback) = isopen(lb.io)
Base.read(fio::FunctionIO, a...) = (call(fio); read(fio.buf, a...))
Base.readavailable(fio::FunctionIO) = (call(fio); readavailable(fio.buf))
Base.readavailable(lb::Loopback) = readavailable(lb.io)
Base.unsafe_read(lb::Loopback, p::Ptr{UInt8}, n::UInt) = unsafe_read(lb.io, p, n)

HTTP.IOExtras.tcpsocket(::Loopback) = TCPSocket()

lbreq(req, headers, body; method="GET", kw...) =
      HTTP.request(method, "http://test/$req", headers, body; config..., kw...)

lbopen(f, req, headers) =
    HTTP.open(f, "PUT", "http://test/$req", headers; config...)

function reset(lb::Loopback)
    truncate(lb.buf, 0)
    lb.got_headers = false
end

"""
    escapelines(string)

Escape `string` and insert '\n' after escaped newline characters.
"""
function escapelines(s::String)
    s = Base.escape_string(s)
    s = replace(s, "\\n" => "\\n\n    ")
    return string("    ", strip(s))
end

function on_headers(f::Function, lb::Loopback)
    if lb.got_headers
        return
    end

    buf = copy(lb.buf)
    seek(buf, 0)
    req = Request()

    try
        readheaders(buf, req)
        lb.got_headers = true
    catch e
        if !(e isa EOFError || e isa HTTP.ParseError)
            rethrow(e)
        end
    end

    if lb.got_headers
            f(req)
    end
end

function on_body(f::Function, lb::Loopback)
    s = String(take!(copy(lb.buf)))
    req = nothing

    try
        req = parse(HTTP.Request, s)
    catch e
        if !(e isa EOFError || e isa HTTP.ParseError)
            rethrow(e)
        end
    end

    if req !== nothing
        reset(lb)
        @async try
            f(req)
        catch e
            println("⚠️ on_body exception: $(sprint(showerror, e))\n$(stacktrace(catch_backtrace()))")
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
        println("📡  $(HTTP.sprintcompact(req))")
        push!(server_events, "Request: $(HTTP.sprintcompact(req))")

        if req.target == "/abort"
            reset(lb)
            response = HTTP.Response(403, ["Connection" => "close",
                                          "Content-Length" => 0]; request=req)
            push!(server_events, "Response: $(HTTP.sprintcompact(response))")
            write(lb.io, response)
        end
    end

    on_body(lb) do req
        l = length(req.body)
        response = HTTP.Response(200, ["Content-Length" => l],
                                      body = req.body; request=req)
        if req.target == "/echo"
            push!(server_events, "Response: $(HTTP.sprintcompact(response))")
            write(lb.io, response)
        elseif (m = match(r"^/delay([0-9]*)$", req.target)) !== nothing
            t = parse(Int, first(m.captures))
            sleep(t/10)
            push!(server_events, "Response: $(HTTP.sprintcompact(response))")
            write(lb.io, response)
        else
            response = HTTP.Response(403,
                                     ["Connection" => "close",
                                      "Content-Length" => 0]; request=req)
            push!(server_events, "Response: $(HTTP.sprintcompact(response))")
            write(lb.io, response)
        end
    end

    return n
end

function HTTP.Connections.getconnection(::Type{Loopback},
    host::AbstractString,
    port::AbstractString;
    kw...)::Loopback
    return Loopback()
end

function async_test(m=["GET","GET","GET","GET","GET"];kw...)
    r1 = r2 = r3 = r4 = r5 = nothing
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

@testset "loopback" begin
    global server_events

    @testset "FunctionIO" begin
        io = FunctionIO(()->"Hello World!")
        @test String(read(io)) == "Hello World!"
    end

    @testset "lbreq - IOBuffer" begin
        r = lbreq("echo", [], ["Hello", IOBuffer(" "), "World!"]);
        @test String(r.body) == "Hello World!"
    end

    @testset "lbreq - FunctionIO" begin
        r = lbreq("echo", [], FunctionIO(()->"Hello World!"))
        @test String(r.body) == "Hello World!"
    end

    @testset "lbreq - Array of Strings" begin
        r = lbreq("echo", [], ["Hello", " ", "World!"]);
        @test String(r.body) == "Hello World!"
    end

    @testset "lbreq - Array of Bytes - Echo" begin
        r = lbreq("echo", [], [HTTP.bytes("Hello"),
                             HTTP.bytes(" "),
                             HTTP.bytes("World!")]);
        @test String(r.body) == "Hello World!"
    end

    @testset "lbreq - Array of Bytes - Delay" begin
        r = lbreq("delay10", [], [HTTP.bytes("Hello"),
                                  HTTP.bytes(" "),
                                  HTTP.bytes("World!")]);
        @test String(r.body) == "Hello World!"
    end

    @testset "lbopen - Body - Delay" begin
        body = Ref{Any}(nothing)
        body_sent = Ref(false)
        r = lbopen("delay10", []) do http
            @sync begin
                @async begin
                    write(http, "Hello World!")
                    closewrite(http)
                    body_sent[] = true
                end
                startread(http)
                body[] = read(http)
                closeread(http)
            end
        end
        @test String(body[]) == "Hello World!"
    end

    # "If [the response] indicates the server does not wish to receive the
    #  message body and is closing the connection, the client SHOULD
    #  immediately cease transmitting the body and close the connection."
    # https://tools.ietf.org/html/rfc7230#section-6.5
    @testset "lbopen - Body - Abort" begin
        body = nothing
        body_aborted = false
        body_sent = false
        @test_throws HTTP.StatusError begin
            r = lbopen("abort", []) do http
                @sync begin
                    event = Base.Event()
                    @async try
                        wait(event)
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
                    notify(event)
                end
            end
        end
        @test body_aborted == true
        @test body_sent == false
    end

    @testset "libreq - Sleep" begin
        r = lbreq("echo", [], [
            FunctionIO(()->(sleep(0.1); "Hello")),
            FunctionIO(()->(sleep(0.1); " World!"))])
        @test String(r.body) == "Hello World!"

        hello_sent = Ref(false)
        world_sent = Ref(false)
        @test_throws HTTP.RequestError begin
            r = lbreq("abort", [], [
                FunctionIO(()->(hello_sent[] = true; sleep(1.0); "Hello")),
                FunctionIO(()->(world_sent[] = true; " World!"))])
        end
        @test hello_sent[]
        @test !world_sent[]
    end

    @testset "ASync - Pipeline limit = 0" begin
        server_events = []
        t = async_test(;pipeline_limit=0)
        if haskey(ENV, "HTTP_JL_TEST_TIMING_SENSITIVE")
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
        end
    end

    @testset "ASync - " begin
        server_events = []
        t = async_test()
        if haskey(ENV, "HTTP_JL_TEST_TIMING_SENSITIVE")
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
    end

    # "A user agent SHOULD NOT pipeline requests after a
    #  non-idempotent method, until the final response
    #  status code for that method has been received"
    # https://tools.ietf.org/html/rfc7230#section-6.3.2
    @testset "ASync - " begin
        server_events = []
        t = async_test(["POST","GET","GET","GET","GET"])
        @test server_events[1:2] == [
            "Request: POST /delay1 HTTP/1.1",
            "Response: HTTP/1.1 200 OK <= (POST /delay1 HTTP/1.1)"]
    end
end

end # module
