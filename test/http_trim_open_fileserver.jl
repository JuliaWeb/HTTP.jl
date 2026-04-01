include("trim_workload_common.jl")

function run_http_trim_open_fileserver()::Nothing
    # Desired future coverage once package-local background Tasks are trim-safe:
    #
    # stream_server = HT.listen!("127.0.0.1", 0) do stream
    #     request = HT.startread(stream)
    #     payload = read(stream, String)
    #     HT.setstatus(stream, 200)
    #     HT.setheader(stream, "Content-Type", "text/plain; charset=utf-8")
    #     write(stream, "stream:" * request.target * ":" * payload)
    #     return nothing
    # end
    #
    # file_server = HT.serve!(HT.fileserver(temp_dir; etag = :weak_stat), "127.0.0.1", 0)
    # stream = HT.open(:POST, "$(trim_http_base_url(stream_server))/stream")
    # static_resp = HT.request("GET", "$(trim_http_base_url(file_server))/hello.txt", Pair{String,String}[], nothing)

    handler = HT.fileserver(".";
        etag = :weak_stat,
        redirect_canonical = true,
    )
    handler isa Function || error("expected fileserver to return a callable handler")

    # Keep a small direct static-response construction in the fallback path so the
    # workload still exercises user-facing response objects around the blocked
    # async server/client network roundtrip.
    response = trim_text_response("static hello")
    response.status == 200 || error("expected fallback response status 200")
    trim_body_string(response.body) == "static hello" || error("unexpected fallback response body")
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_http_trim_open_fileserver()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
