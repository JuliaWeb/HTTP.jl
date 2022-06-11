using Test, Sockets, Deno_jll, HTTP

# Not all architectures have a Deno_jll
hasproperty(Deno_jll, :deno) && @testset "WebSocket server" begin
    port = 36984
    server = listen(Sockets.localhost, port)
    # Will contain a list of received messages
    server_received_messages = []
    # Start the server async
    @async try
        WebSockets.listen(Sockets.localhost, port; server=server) do ws
            for msg in ws
                push!(server_received_messages, msg)
                if msg == "close"
                    close(ws)
                else
                    response = "Hello, " * msg
                    send(ws, response)
                end
            end
        end
    catch e
        @error "WebSocket server error" exception=(e,catch_backtrace())
        rethrow(e)
    end

    try
        # Run our client tests using Deno
        # this throws error if the Deno tests fail
        @test success(run(`$(Deno_jll.deno()) test --allow-net`))
        @test server_received_messages == ["world", "close"]
    finally
        close(server)
    end
end