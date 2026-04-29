using HTTP
using Reseau

const HT = HTTP

function trim_http_base_url(server; scheme::AbstractString = "http")::String
    return string(scheme, "://", HT.server_addr(server))
end

function trim_body_string(body::HT.AbstractBody)::String
    out = UInt8[]
    buf = Vector{UInt8}(undef, 256)
    while true
        n = HT.body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    HTTP.@try_ignore HT.body_close!(body)
    return String(out)
end

trim_body_string(body::AbstractVector{UInt8}) = String(body)
trim_body_string(body::AbstractString) = String(body)

function trim_text_response(
    text::AbstractString;
    status::Integer = 200,
    headers = Pair{String,String}[],
    proto_major::Integer = 1,
    proto_minor::Integer = 1,
)
    payload = String(text)
    body = HT.BytesBody(collect(codeunits(payload)))
    return HT._response_nocopy_exact(
        Int(status),
        "",
        HT.Headers(headers),
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
    HTTP.@try_ignore HT.forceclose(server)
    HTTP.@try_ignore wait(server)
    return nothing
end

function trim_raw_http_exchange(port::Integer, request::AbstractString)::String
    conn = Reseau.TCP.connect(Reseau.TCP.loopback_addr(port))
    try
        write(conn, request)
        closewrite(conn)
        return String(read(conn))
    finally
        HTTP.@try_ignore close(conn)
    end
end
