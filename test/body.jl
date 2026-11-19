using HTTP.Messages

@testset "HTTP.Bodies" begin

    @test String(take!(Body("Hello!"))) == "Hello!"
    @test String(take!(Body(IOBuffer("Hello!")))) == "Hello!"
    @test String(take!(Body(Vector{UInt8}("Hello!")))) == "Hello!"
    @test String(take!(Body())) == ""

    io = BufferStream()
    @async begin
        write(io, "Hello")
        sleep(0.1)
        write(io, "!")
        sleep(0.1)
        close(io)
    end
    @test String(take!(Body(io))) == "5\r\nHello\r\n1\r\n!\r\n0\r\n\r\n"

    b = Body()
    write(b, "Hello")
    write(b, "!")
    @test String(take!(b)) == "Hello!"

    io = BufferStream()
    b = Body(io)
    write(b, "Hello")
    write(b, "!")
    @test String(readavailable(io)) == "Hello!"

    #display(b); println()

    buf = IOBuffer()
    show(buf, b)
    @test String(take!(buf)) == "Hello!\n⋮\nWaiting for BufferStream...\n"

    write(b, "\nWorld!")
    close(io)

    #display(b); println()
    buf = IOBuffer()
    show(buf, b)
    @test String(take!(buf)) == "Hello!\nWorld!\n"

    tmp = HTTP.Messages.Bodies.body_show_max
    HTTP.Messages.Bodies.set_show_max(12)
    b = Body("Hello World!xxx")
    #display(b); println()
    buf = IOBuffer()
    show(buf, b)
    @test String(take!(buf)) == "Hello World!\n⋮\n15-byte body\n"
    HTTP.Messages.Bodies.set_show_max(tmp)
end
