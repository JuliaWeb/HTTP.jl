using HTTP
using HTTP: hasheader
using MbedTLS

@static if Sys.isapple()
    launch(x) = run(`open $x`)
elseif Sys.islinux()
    launch(x) = run(`xdg-open $x`)
elseif Sys.iswindows()
    launch(x) = run(`cmd /C start $x`)
end

@test_skip @testset "MWE" begin
    @async begin
        sleep(2)
        launch("https://127.0.0.1:8000/examples/mwe")
    end

    HTTP.listen("127.0.0.1", 8000;
                sslconfig = MbedTLS.SSLConfig(joinpath(dirname(@__FILE__), "resources/cert.pem"),
                                              joinpath(dirname(@__FILE__), "resources/key.pem"))) do http

        if HTTP.WebSockets.is_websocket_upgrade(http.message)
            HTTP.WebSockets.upgrade(http) do client
                count = 1
                while !eof(client);
                    msg = String(readavailable(client))
                    println(msg)
                    write(client, "Hello JavaScript! From Julia $count")
                    count += 1
                end
            end
        else
            h = HTTP.Handlers.RequestHandlerFunction() do req::HTTP.Request
                HTTP.Response(200,read(joinpath(dirname(@__FILE__),"resources/mwe.html"), String))
            end
            HTTP.Handlers.handle(h, http)
        end
    end
end