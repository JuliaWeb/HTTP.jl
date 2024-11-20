using PrecompileTools: @setup_workload, @compile_workload

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

    server = HTTP.serve!("0.0.0.0", _port; verbose = -1, listenany=true) do req
        HTTP.Response(200,  ["Content-Encoding" => "gzip"], gzip_data("dummy response"))
    end
    # listenany allows changing port if that one is already in use, so check the actual port
    _port = HTTP.port(server)

    @compile_workload begin
        HTTP.get("http://localhost:$_port")
    end

    HTTP.forceclose(server)
    server = nothing
end
