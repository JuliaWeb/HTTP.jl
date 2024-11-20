using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    # TODO: Are these all safe to call here and bake into the pkgimage?
    Connections.__init__()
    MultiPartParsing.__init__()
    Parsers.__init__()
    ConnectionRequest.__init__()

    gzip_data(data::String) = read(GzipCompressorStream(IOBuffer(data)))

    server = HTTP.serve!("0.0.0.0"; verbose = -1, listenany=true) do req
        HTTP.Response(200,  ["Content-Encoding" => "gzip"], gzip_data("dummy response"))
    end
    _port = HTTP.port(server)

    @compile_workload begin
        HTTP.get("http://localhost:$_port")
    end

    HTTP.forceclose(server)
    server = nothing
end
