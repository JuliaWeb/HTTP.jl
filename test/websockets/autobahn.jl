@testitem "Autobahn WebSocket Tests" begin

using Test, Sockets, HTTP, HTTP.WebSockets, JSON

const DIR = abspath(joinpath(dirname(pathof(HTTP)), "../test/websockets"))

havedocker = success(`which docker`)
!havedocker && @warn "Docker not found, skipping Autobahn tests"

# 32-bit not supported by autobahn
if Int === Int64 && !Sys.iswindows() && havedocker

if length(split(read(`docker images crossbario/autobahn-testsuite`, String), '\n'; keepempty=false)) < 2
    @assert success(`docker pull crossbario/autobahn-testsuite`)
end


@testset "Client" begin
    # Run the autobahn test suite in a docker container
    serverproc = run(Cmd(`docker run --rm -v "$DIR/config:/config" -v "$DIR/reports:/reports" -p 9001:9001 --name fuzzingserver crossbario/autobahn-testsuite`; dir=DIR), stdin, stdout, stdout; wait=false)
    try
        sleep(5) # give time for server to get setup
        cases = Ref(0)
        runtests = Ref(true)
        try
            WebSockets.open("ws://127.0.0.1:9001/getCaseCount") do ws
                for msg in ws
                    cases[] = parse(Int, msg)
                end
            end
        catch e
            @error "problem getting autobahn case count" exception=(e, catch_backtrace())
            @show serverproc
            runtests[] = false
        end

        if runtests[]
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
        end
    finally
        # stop/remove server process
        kill(serverproc)
    end
end # @testset "Client"

@testset "Server" begin
    server = WebSockets.listen!(9002; suppress_close_error=true) do ws
        for msg in ws
            send(ws, msg)
        end
    end
    try
        rm(joinpath(DIR, "reports/server/index.json"); force=true)
        @test success(run(Cmd(`docker run --rm --net="host" -v "$DIR/config:/config" -v "$DIR/reports:/reports" --name fuzzingclient crossbario/autobahn-testsuite wstest -m fuzzingclient -s /config/fuzzingclient.json`; dir=DIR), stdin, stdout, stdout; wait=false))
        report = JSON.parsefile(joinpath(DIR, "reports/server/index.json"))
        for (k, v) in pairs(report["main"])
            @test v["behavior"] in ("OK", "NON-STRICT", "INFORMATIONAL", "UNIMPLEMENTED")
        end
    finally
        close(server)
    end
end # @testset "Server"

end # 64-bit only

end # @testitem
