using SnoopPrecompile
@precompile_all_calls begin
    resize!(empty!(Parsers.status_line_regex),           Threads.nthreads())
    resize!(empty!(Parsers.request_line_regex),          Threads.nthreads())
    resize!(empty!(Parsers.header_field_regex),          Threads.nthreads())
    resize!(empty!(Parsers.obs_fold_header_field_regex), Threads.nthreads())
    resize!(empty!(Parsers.empty_header_field_regex),    Threads.nthreads())
    router = Router()
    register!(router, "GET", "/read/**", _ -> Response(200))
    server = HTTP.serve!(router, "0.0.0.0", 8080; listenany=true)
    try
        resp = get("http://localhost:$(port(server))/read//$(homedir())")
    finally
        close(server)
    end
end
