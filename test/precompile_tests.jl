@testset "HTTP precompile workload cleanup" begin
    @test HTTP._precompile_host_resolver_available() isa Bool
    @test HTTP._run_precompile_workload!() === nothing
    @test HTTP._precompile_shutdown!() === nothing
end

precompile_probe(req::HTTP.Request) = HTTP.Response(200, "ok")
function precompile_stream_probe(stream::HTTP.Stream)
    HTTP.startread(stream)
    write(stream, "ok")
    return nothing
end

# Method instances of HTTP's named functions that are specialized for a server of type `S`.
function _server_specializations(S::Type)::Set{Core.MethodInstance}
    found = Set{Core.MethodInstance}()
    for name in names(HTTP; all = true)
        isdefined(HTTP, name) || continue
        f = getglobal(HTTP, name)
        f isa Function || continue
        for m in methods(f), mi in Base.specializations(m)
            mi isa Core.MethodInstance && mi.specTypes isa DataType || continue
            S in mi.specTypes.parameters && push!(found, mi)
        end
    end
    return found
end

@testset "precompile_server leaves nothing for the first requests to compile" begin
    for (start!, handler) in ((HTTP.serve!, precompile_probe), (HTTP.listen!, precompile_stream_probe))
        @test HTTP.precompile_server(typeof(handler))
        server = start!(handler, "127.0.0.1", 0; listenany = true)
        try
            url = "http://127.0.0.1:$(HTTP.port(server))/"
            compiled = _server_specializations(HTTP.Server{typeof(handler)})
            for protocol in (:h1, :h2)
                response = HTTP.get(url; protocol = protocol)
                @test response.status == 200
                @test String(response.body) == "ok"
            end
            @test setdiff(_server_specializations(HTTP.Server{typeof(handler)}), compiled) == Set{Core.MethodInstance}()
        finally
            HTTP.forceclose(server)
        end
    end
end
