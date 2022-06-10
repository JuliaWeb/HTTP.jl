module TestWebSockets

using Test, Sockets, HTTP, HTTP.WebSockets, JSON

const DIR = joinpath(dirname(pathof(HTTP)), "../test/websockets")

@testset "WebSockets" begin

@show success(`which docker`)
if success(`which docker`) && !Sys.iswindows()
    @testset "Autobahn testsuite" begin
        p = run(Cmd(`docker run -d --rm --name abserver -v "$DIR/config:/config" -v "$DIR/reports:/reports" -p 9001:9001 crossbario/autobahn-testsuite`; dir=DIR); wait=false)
        sleep(5) # give time for server to get setup
        cases = Ref(0)
        WebSockets.open("ws://127.0.0.1:9001/getCaseCount") do ws
            for msg in ws
                cases[] = parse(Int, msg)
            end
        end

        for i = 1:cases[]
            # println("Running test case = $i")
            verbose = false
            try
                WebSockets.open("ws://127.0.0.1:9001/runCase?case=$(i)&agent=main"; verbose, suppress_close_error=true) do ws
                    for msg in ws
                        send(ws, msg)
                    end
                end
            catch
                # ignore errors here since we want to run all cases + some are expected to throw
            end
        end

        rm(joinpath(DIR, "reports/clients/index.json"); force=true)
        WebSockets.open("ws://127.0.0.1:9001/updateReports?agent=main") do ws
            for msg in ws
                send(ws, msg)
            end
        end
        
        report = JSON.parsefile(joinpath(DIR, "reports/clients/index.json"))
        for (k, v) in pairs(report["main"])
            @test v["behavior"] in ("OK", "NON-STRICT", "INFORMATIONAL")
        end
        # stop/remove docker server container
        run(Cmd(`docker rm -f abserver`; ignorestatus=true))
    end # @testset "Autobahn testsuite"

    @testset "Autobahn testsuite server" begin
        server = Sockets.listen(Sockets.localhost, 9002)
        ready_to_accept = Ref(false)
        @async WebSockets.listen(Sockets.localhost, 9002; server, ready_to_accept, suppress_close_error=true) do ws
            for msg in ws
                send(ws, msg)
            end
        end
        while !ready_to_accept[]
            sleep(0.5)
        end
        rm(joinpath(DIR, "reports/server/index.json"); force=true)
        @test success(run(Cmd(`docker run -d --rm --name abclient -v "$DIR/config:/config" -v "$DIR/reports:/reports" --network="host" crossbario/autobahn-testsuite wstest -m fuzzingclient -s config/fuzzingclient.json`; dir=DIR)))
        @test success(run(`docker wait abclient`))
        close(server)
        report = JSON.parsefile(joinpath(DIR, "reports/server/index.json"))
        for (k, v) in pairs(report["main"])
            @test v["behavior"] in ("OK", "NON-STRICT", "INFORMATIONAL", "UNIMPLEMENTED")
        end
    end
    
end

end # @testset "WebSockets"

# @testset "WebSockets" begin
#     p = 8085 # rand(8000:8999)
#     socket_type = ["wss", "ws"]

#     function listen_localhost()
#         server = Sockets.listen(Sockets.localhost, p)
#         tsk = @async HTTP.listen(Sockets.localhost, p; server=server) do http
#             if WebSockets.isupgrade(http.message)
#                 WebSockets.upgrade(http) do ws
#                     while !eof(ws)
#                         data = readavailable(ws)
#                         println("Received: $(String(copy(data))), echoing back")
#                         write(ws, data)
#                     end
#                 end
#             end
#         end
#         return server
#     end

#     if !isempty(get(ENV, "PIE_SOCKET_API_KEY", "")) && get(ENV, "JULIA_VERSION", "") == "1"
#         println("found pie socket api key, running External Host websocket tests")
#         pie_socket_api_key = ENV["PIE_SOCKET_API_KEY"]
#         @testset "External Host - $s" for s in socket_type
#             WebSockets.open("$s://free3.piesocket.com/v3/http_test_channel?api_key=$pie_socket_api_key&notify_self") do ws
#                 println("opened websocket; writing Foo")
#                 write(ws, "Foo")
#                 @test !eof(ws)
#                 @test String(readavailable(ws)) == "Foo"
#             end

#                 write(ws, "Foo"," Bar")
#                 @test !eof(ws)
#                 @test String(readavailable(ws)) == "Foo Bar"

#                 # send fragmented message manually with ping in between frames
#                 # WebSockets.wswrite(ws, ws.frame_type, "Hello ")
#                 # WebSockets.wswrite(ws, WebSockets.WS_FINAL | WebSockets.WS_PING, "things")
#                 # WebSockets.wswrite(ws, WebSockets.WS_FINAL, "again!")
#                 # @test String(readavailable(ws)) == "Hello again!"

#                 write(ws, "Hello")
#                 write(ws, " There")
#                 write(ws, " World", "!")
#                 IOExtras.closewrite(ws)

#                 buf = IOBuffer()
#                 # write(buf, ws)
#                 @test_skip String(take!(buf)) == "Hello There World!"
#             end
#         end
#     end
# end

end # module