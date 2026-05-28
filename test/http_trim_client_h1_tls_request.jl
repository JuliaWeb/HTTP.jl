include("trim_workload_common.jl")

const TRIM_TLS = Reseau.TLS

function trim_tls_config(cert_file::String, key_file::String)::TRIM_TLS.Config
    return TRIM_TLS.Config(
        nothing,
        false,
        false,
        TRIM_TLS.ClientAuthMode.NoClientCert,
        cert_file,
        key_file,
        nothing,
        nothing,
        ["http/1.1"],
        UInt16[],
        Int64(0),
        TRIM_TLS.TLS1_2_VERSION,
        nothing,
        false,
        64,
    )
end

function run_http_trim_client_h1_tls_request()::Nothing
    server = nothing
    try
        resource_dir = joinpath(@__DIR__, "resources")
        cert_file = joinpath(resource_dir, "unittests.crt")
        key_file = joinpath(resource_dir, "unittests.key")
        listener = TRIM_TLS.listen(
            "tcp",
            "127.0.0.1:0",
            trim_tls_config(cert_file, key_file);
            backlog = 128,
        )
        server = HT.serve!(listener) do request
            request.method == "GET" || return trim_text_response("missing"; status = 404)
            request.target == "/tls-request" || return trim_text_response("missing"; status = 404)
            return trim_text_response("h1-tls-request")
        end
        yield()

        url = "$(trim_http_base_url(server; scheme = "https"))/tls-request"
        response = HT.request(
            "GET",
            url;
            proxy = HT.ProxyConfig(),
            protocol = :h1,
            retry = false,
            redirect = false,
            cookies = false,
            require_ssl_verification = false,
            connect_timeout = 1.0,
            request_timeout = 5.0,
            response_header_timeout = 5.0,
            read_idle_timeout = 5.0,
            write_idle_timeout = 5.0,
        )
        response.status == 200 || error("expected 200 response, got $(response.status)")
        body = response.body
        body isa Vector{UInt8} || error("expected Vector{UInt8} response body")
        String(body::Vector{UInt8}) == "h1-tls-request" || error("unexpected response body")
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
    run_http_trim_client_h1_tls_request()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
