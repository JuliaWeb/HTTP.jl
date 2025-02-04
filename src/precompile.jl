using PrecompileTools: @setup_workload, @compile_workload

try
    @setup_workload begin
        HTTP.__init__()
        @info "HTTP initialized"
        gzip_data(data::String) = read(GzipCompressorStream(IOBuffer(data)))
        # random port in the dynamic/private range (49152–65535) which are are
        # least likely to be used by well-known services
        _port = 57813
        server = HTTP.serve!("0.0.0.0", _port; listenany=true) do req
            HTTP.Response(200,  ["Content-Encoding" => "gzip"], gzip_data("dummy response"))
        end
        # listenany allows changing port if that one is already in use, so check the actual port
        _port = HTTP.port(server)
        url = "http://localhost:$_port"
        env = ["JULIA_NO_VERIFY_HOSTS" => "localhost",
            "JULIA_SSL_NO_VERIFY_HOSTS" => nothing,
            "JULIA_ALWAYS_VERIFY_HOSTS" => nothing]
        @info "HTTP server started on port $_port"
        try
            withenv(env...) do
                @compile_workload begin
                    @show HTTP.get(url)
                end
            end
        finally
            @info "Shutting down HTTP server"
            close(server)
            @info "HTTP server shut down"
            yield() # needed on 1.9 to avoid some issue where it seems a task doesn't stop before serialization
            server = nothing
            close_all_clients!()
            close_default_aws_server_bootstrap!()
            close_default_aws_client_bootstrap!()
            close_default_aws_host_resolver!()
            close_default_aws_event_loop_group!()
        end
    end
catch e
    @info "Ignoring an error that occurred during the precompilation workload" exception=(e, catch_backtrace())
end
