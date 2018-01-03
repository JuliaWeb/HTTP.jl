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

    if !isopen(lb.buf)
        throw(ArgumentError("stream is closed or unusable"))
    end

    n = unsafe_write(lb.buf, p, n)
    
    on_headers(lb) do req

        println("📡  $(sprint(showcompact, req))")

        if req.uri == "/abort"
            reset(lb)
            response = HTTP.Response(403, ["Connection" => "close",
                                          "Content-Length" => 0])
            write(lb.io, response)
        end
    end

    on_body(lb) do req

        l = length(req.body)
        response = HTTP.Response(200, ["Content-Length" => l],
                                      body = req.body)
        if req.uri == "/echo"
            write(lb.io, response)
        elseif req.uri == "/delay"
            sleep(0.1)
            write(lb.io, response)
        else
            response = HTTP.Response(403,
                                     ["Connection" => "close",
                                      "Content-Length" => 0])
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
    :retry => false
]

lbget(req, headers, body) =
      HTTP.request("GET", "http://test/$req", headers, body; config...)

lbopen(f, req, headers) =
    HTTP.open(f, "GET", "http://test/$req", headers; config...)

@testset "loopback" begin

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
end


