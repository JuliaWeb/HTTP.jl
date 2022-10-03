using SnoopPrecompile
@precompile_all_calls begin
    resize!(empty!(Parsers.status_line_regex),           Threads.nthreads())
    resize!(empty!(Parsers.request_line_regex),          Threads.nthreads())
    resize!(empty!(Parsers.header_field_regex),          Threads.nthreads())
    resize!(empty!(Parsers.obs_fold_header_field_regex), Threads.nthreads())
    resize!(empty!(Parsers.empty_header_field_regex),    Threads.nthreads())
    port, server = listenany(ip"0.0.0.0", 8080)
    router = Router()
    register!(router, "GET", "/read/**", _ -> Response(200))
    t = @async serve(router, "0.0.0.0", port, server=server)
    resp = get("http://localhost:$port/read//$(homedir())")
end
