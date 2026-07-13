include("trim_workload_common.jl")

# Exercises the server response-write path over every body shape the narrowing
# helpers (`_with_response_narrowed` / `_with_body_narrowed`) cover: String,
# SubString{String}, Vector{UInt8}, nothing, EmptyBody, and BytesBody{Vector{UInt8}}.
# The handler's mixed return type also forces the widened-response boundary, so the
# `_write_all_response_dyn!` shim itself is on the compiled path. Guards the
# response-write machinery against trim regressions.

function shapes_handler(request::HT.Request)
    target = request.target
    if target == "/string"
        return HT.Response(200, ["Content-Type" => "text/plain"], "body-string")
    elseif target == "/substring"
        return HT.Response(200, ["Content-Type" => "text/plain"], SubString("xx-body-substring-yy", 4, 17))
    elseif target == "/bytes"
        return HT.Response(200, ["Content-Type" => "application/octet-stream"], UInt8[0x62, 0x6f, 0x64, 0x79])
    elseif target == "/bytesbody"
        return HT.Response(200, ["Content-Type" => "application/octet-stream"], HT.BytesBody(UInt8[0x62, 0x62]))
    elseif target == "/empty"
        return HT.Response(200, ["Content-Type" => "text/plain"], HT.EmptyBody())
    else
        return HT.Response(204)
    end
end

function trim_expect_response(port::Integer, target::String, expected_status::String, expected_body::String)::Nothing
    response = trim_raw_http_exchange(port,
        "GET $(target) HTTP/1.1\r\n" *
        "Host: 127.0.0.1:$(port)\r\n" *
        "Connection: close\r\n" *
        "\r\n",
    )
    startswith(response, expected_status) || error("unexpected status for $(target): $(repr(response))")
    if !isempty(expected_body)
        occursin("\r\n\r\n" * expected_body, response) || error("unexpected body for $(target): $(repr(response))")
    end
    return nothing
end

function run_http_trim_server_response_shapes()::Nothing
    server = nothing
    try
        server = HT.serve!(shapes_handler, "127.0.0.1", 0; listenany = true)
        port = HT.port(server)
        trim_expect_response(port, "/string", "HTTP/1.1 200 OK\r\n", "body-string")
        trim_expect_response(port, "/substring", "HTTP/1.1 200 OK\r\n", "body-substring")
        trim_expect_response(port, "/bytes", "HTTP/1.1 200 OK\r\n", "body")
        trim_expect_response(port, "/bytesbody", "HTTP/1.1 200 OK\r\n", "bb")
        trim_expect_response(port, "/empty", "HTTP/1.1 200 OK\r\n", "")
        trim_expect_response(port, "/nothing", "HTTP/1.1 204", "")
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
    run_http_trim_server_response_shapes()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
