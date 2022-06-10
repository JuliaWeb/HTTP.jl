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
    dir = joinpath(dirname(pathof(HTTP)), "../test")
    HTTP.listen("127.0.0.1", 8000;
                sslconfig = MbedTLS.SSLConfig(joinpath(dir, "resources/cert.pem"),
                                              joinpath(dir, "resources/key.pem"))) do http

        if HTTP.WebSockets.isupgrade(http.message)
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
                HTTP.Response(200,read(joinpath(dir, "resources/mwe.html"), String))
            end
            HTTP.Handlers.handle(h, http)
        end
    end
end
