using PrecompileTools: @setup_workload, @compile_workload

try
    @setup_workload begin
        # These need to be safe to call here and bake into the pkgimage, i.e. called twice.
        Connections.__init__()
        MultiPartParsing.__init__()
        Parsers.__init__()

        # Doesn't seem to be needed here, and might not be safe to call twice (here and during runtime)
        # ConnectionRequest.__init__()

        gzip_data(data::String) = read(GzipCompressorStream(IOBuffer(data)))

        # random port in the dynamic/private range (49152–65535) which are are
        # least likely to be used by well-known services
        _port = 57813

        cert, key = joinpath.(@__DIR__, "../test", "resources", ("cert.pem", "key.pem"))
        sslconfig = MbedTLS.SSLConfig(cert, key)

        server = HTTP.serve!("0.0.0.0", _port; verbose = -1, listenany=true, sslconfig=sslconfig) do req
            HTTP.Response(200,  ["Content-Encoding" => "gzip"], gzip_data("dummy response"))
        end
        try
            # listenany allows changing port if that one is already in use, so check the actual port
            _port = HTTP.port(server)
            url = "https://localhost:$_port"

            env = ["JULIA_NO_VERIFY_HOSTS" => "localhost",
                "JULIA_SSL_NO_VERIFY_HOSTS" => nothing,
                "JULIA_ALWAYS_VERIFY_HOSTS" => nothing]

            @compile_workload begin
                withenv(env...) do
                    HTTP.get(url);
                end
            end
        finally
            HTTP.forceclose(server)
            yield() # needed on 1.9 to avoid some issue where it seems a task doesn't stop before serialization
            server = nothing
        end
    end
catch e
    @info "Ignoring an error that occurred during the precompilation workload" exception=(e, catch_backtrace())
end
