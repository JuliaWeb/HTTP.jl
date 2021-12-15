using Test, HTTP, JSON

const dir = joinpath(dirname(pathof(HTTP)), "..", "test")
include(joinpath(dir, "resources/TestRequest.jl"))


using Sockets
@testset "Incomplete response with known content length" begin
    server = Sockets.listen(ip"0.0.0.0", 8080)
    try
        task = @async HTTP.listen("0.0.0.0", 8080; server=server) do http
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Length" => "64") # Promise 64 bytes...
            HTTP.startwrite(http)
            HTTP.write(http, rand(UInt8, 63)) # ...but only send 63 bytes.
            # Close the stream so that eof(stream) is true and the client isn't
            # waiting forever for the last byte.
            HTTP.close(http.stream)
        end

        err = try
            HTTP.get("http://localhost:8080"; retry=false)
        catch err
            @error "error" exception=(err, catch_backtrace())
            err
        end
        @test err isa HTTP.IOError
        @test err.e isa EOFError

    finally
        # Shutdown
        try; close(server); wait(task); catch; end
        HTTP.ConnectionPool.closeall()
    end
end

exit(0)

@testset "HTTP" begin
    for f in [
              "ascii.jl",
              "chunking.jl",
              "utils.jl",
              "client.jl",
              "multipart.jl",
              "parsemultipart.jl",
              "sniff.jl",
              "cookies.jl",
              "parser.jl",
              "loopback.jl",
              "websockets.jl",
              "messages.jl",
              "handlers.jl",
              "server.jl",
              "async.jl",
              "aws4.jl",
              "insert_layers.jl",
              "mwe.jl",
             ]
        file = joinpath(dir, f)
        println("Running $file tests...")
        if isfile(file)
            include(file)
        else
            @show readdir(dirname(file))
        end
    end
end
