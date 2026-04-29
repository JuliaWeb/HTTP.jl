include("trim_workload_common.jl")

function run_http_trim_client_h1_request()::Nothing
    server = nothing
    try
        # This is the single high-level trim frontier workload: public
        # `HTTP.serve!` on the server side and public `HTTP.request(...)`
        # on the client side.
        server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            request.method == "GET" || return trim_text_response("missing"; status = 404)
            request.target == "/request" || return trim_text_response("missing"; status = 404)
            return trim_text_response("h1-request")
        end

        url = "$(trim_http_base_url(server))/request"
        response = HT.request(
            "GET",
            url;
            proxy = HT.ProxyConfig(),
            protocol = :h1,
            retry = false,
            redirect = false,
            cookies = false,
        )
        response.status == 200 || error("expected 200 response, got $(response.status)")
        body = response.body
        body isa Vector{UInt8} || error("expected Vector{UInt8} response body")
        String(body::Vector{UInt8}) == "h1-request" || error("unexpected response body")
    finally
        server === nothing || trim_close_http_server(server::HT.Server)
        yield()
        GC.gc()
        HTTP.@try_ignore Reseau.IOPoll.shutdown!()
    end
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_http_trim_client_h1_request()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
