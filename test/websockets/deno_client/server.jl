import Deno_jll
import HTTP
using Test
using Sockets


# Not all architectures have a Deno_jll
hasproperty(Deno_jll, :deno) && @testset "WebSocket server" begin
    
    # Set up the references needed for a clean shutdown
    server_task_ref = Ref{Any}(nothing)
    closing_ref = Ref{Bool}(false)
    
    server = listen(IPv4(0), 36984)
    function close_it()
        closing_ref[] = true
        close(server)
    end
    
    # Start the server async
    server_task_ref[] = @async try
        HTTP.WebSockets.listen("127.0.0.1", UInt16(36984); server=server) do ws
            while isopen(ws.io)
                data = readavailable(ws)
                msg = String(data)
                # @info "Message received!" string(msg)
                if msg == "close"
                    close(ws.io)
                    close_it()
                else
                    response = "Hello, " * msg
                    write(ws, response)
                end
            end
        end
    catch e
        if closing_ref[] && (e isa Base.IOError)
            # this is "expected"
        else
            @error "WebSocket server error" exception=(e,catch_backtrace())
            rethrow(e)
        end
    end

    success = try
        # Run our client tests using Deno
        # this throws error if the Deno tests fail
        run(`$(Deno_jll.deno()) test --allow-net`)
        true
    catch e
        if e isa ProcessFailedException
            false
        else
            rethrow(e)
        end
    finally
        close_it()
        wait(server_task_ref[])
    end
    @test success
end