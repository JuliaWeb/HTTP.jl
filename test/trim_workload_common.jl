using HTTP
using Reseau

const HT = HTTP

function trim_wait_value(fetcher::Function; timeout_s::Float64 = 5.0)
    deadline = time() + timeout_s
    while time() < deadline
        try
            return fetcher()
        catch
            sleep(0.01)
        end
    end
    return fetcher()
end

function trim_http_base_url(server; scheme::AbstractString = "http")::String
    return string(scheme, "://127.0.0.1:", trim_wait_http_server_port(server))
end

function trim_wait_http_server_port(server; timeout_s::Float64 = 5.0)::Int
    return trim_wait_value(;
        timeout_s = timeout_s,
    ) do
        port = HT.port(server)
        port == 0 && error("server port not ready")
        return port
    end
end

function trim_body_string(body::HT.AbstractBody)::String
    out = UInt8[]
    buf = Vector{UInt8}(undef, 256)
    while true
        n = HT.body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    try
        HT.body_close!(body)
    catch
    end
    return String(out)
end

trim_body_string(body::AbstractVector{UInt8}) = String(body)
trim_body_string(body::AbstractString) = String(body)

function trim_text_response(
    text::AbstractString;
    status::Integer = 200,
    proto_major::Integer = 1,
    proto_minor::Integer = 1,
)
    payload = String(text)
    body = HT.BytesBody(collect(codeunits(payload)))
    return HT._response_nocopy_exact(
        Int(status),
        "",
        HT.Headers(),
        HT.Headers(),
        body,
        Int64(ncodeunits(payload)),
        UInt8(proto_major),
        UInt8(proto_minor),
        false,
        nothing,
        nothing,
        nothing,
        0,
    )
end

function trim_close_http_server(server)::Nothing
    try
        HT.forceclose(server)
    catch
    end
    try
        wait(server)
    catch
    end
    return nothing
end

function trim_raw_http_exchange(port::Integer, request::AbstractString)::String
    conn = Reseau.TCP.connect(Reseau.TCP.loopback_addr(port))
    try
        write(conn, request)
        closewrite(conn)
        return String(read(conn))
    finally
        try
            close(conn)
        catch
        end
    end
end
