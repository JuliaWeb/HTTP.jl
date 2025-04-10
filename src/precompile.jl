using PrecompileTools: @setup_workload, @compile_workload

try
    @setup_workload begin
        HTTP.__init__()
        # HTTP.set_log_level!(4)
        gzip_data(data::String) = read(GzipCompressorStream(IOBuffer(data)))
        @compile_workload begin
            # random port in the dynamic/private range (49152–65535) which are are
            # least likely to be used by well-known services
            _port = 57813
            server = HTTP.serve!("0.0.0.0", _port; listenany=true) do req
                HTTP.Response(200,  ["Content-Encoding" => "gzip"], gzip_data("dummy response"))
            end
            # listenany allows changing port if that one is already in use, so check the actual port
            _port = HTTP.port(server)
            url = "http://localhost:$_port"
            try
                HTTP.get(url)
            finally
                close(server)
                yield() # needed on 1.9 to avoid some issue where it seems a task doesn't stop before serialization
                server = nothing
                close_all_clients!()
                close_default_aws_server_bootstrap!()
                close_default_aws_client_bootstrap!()
                close_default_aws_host_resolver!()
                close_default_aws_event_loop_group!()
            end
        end
    end
catch e
    @info "Ignoring an error that occurred during the precompilation workload" exception=(e, catch_backtrace())
end
