using Test, Sockets, HTTP, HTTP.WebSockets, JSON

const DIR = abspath(joinpath(dirname(pathof(HTTP)), "../test/websockets"))

# 32-bit not supported by autobahn
if Int === Int64 && !Sys.iswindows()

@testset "Autobahn WebSocket Tests" begin

@testset "Client" begin
    serverproc = run(Cmd(`wstest -u 0 -m fuzzingserver -s config/fuzzingserver.json`; dir=DIR), stdin, stdout, stdout; wait=false)
    sleep(1) # give time for server to get setup
    cases = Ref(0)
    WebSockets.open("ws://127.0.0.1:9001/getCaseCount") do ws
        for msg in ws
            cases[] = parse(Int, msg)
        end
    end

    for i = 1:cases[]
        println("Running test case = $i")
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
    sleep(1)
    try
        WebSockets.open("ws://127.0.0.1:9001/updateReports?agent=main") do ws
            receive(ws)
        end
    catch
        WebSockets.open("ws://127.0.0.1:9001/updateReports?agent=main") do ws
            receive(ws)
        end
    end
    
    report = JSON.parsefile(joinpath(DIR, "reports/clients/index.json"))
    for (k, v) in pairs(report["main"])
        @test v["behavior"] in ("OK", "NON-STRICT", "INFORMATIONAL")
    end
    # stop/remove server process
    kill(serverproc)
end # @testset "Autobahn testsuite"

@testset "Server" begin
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
    @test success(run(Cmd(`wstest -u 0 -m fuzzingclient -s config/fuzzingclient.json`; dir=DIR)))
    close(server)
    report = JSON.parsefile(joinpath(DIR, "reports/server/index.json"))
    for (k, v) in pairs(report["main"])
        @test v["behavior"] in ("OK", "NON-STRICT", "INFORMATIONAL", "UNIMPLEMENTED")
    end
end

end # @testset "WebSockets"

end # 64-bit only