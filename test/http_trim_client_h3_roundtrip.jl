include("trim_workload_common.jl")

const _HTTP_TRIM_H3_CERT = joinpath(@__DIR__, "resources", "unittests.crt")
const _HTTP_TRIM_H3_KEY = joinpath(@__DIR__, "resources", "unittests.key")
const _HTTP_TRIM_H3_LISTENER = Ref{Union{Nothing,Reseau.QUIC.Listener}}(nothing)

function _http_trim_h3_frame(type::UInt64, payload::Vector{UInt8})::Vector{UInt8}
    out = UInt8[]
    HT._h3_append_frame!(out, type, payload)
    return out
end

# Serves one HTTP/3 request on one connection: SETTINGS on a control stream,
# then a fixed response to a GET for /h3-roundtrip.
function _http_trim_h3_server_entry()::Nothing
    listener = _HTTP_TRIM_H3_LISTENER[]::Reseau.QUIC.Listener
    conn = Reseau.QUIC.accept(listener)
    try
        control = Reseau.QUIC.open_stream(conn; bidi = false)
        out = UInt8[]
        HT._h3_append_varint!(out, HT._H3_STREAM_CONTROL)
        append!(out, _http_trim_h3_frame(HT._H3_FRAME_SETTINGS, UInt8[]))
        write(control, out)
        while true
            s = Reseau.QUIC.accept_stream(conn)
            Reseau.QUIC.isbidi(s) || continue
            header = HT._h3_read_frame_header(s)
            header === nothing && error("expected a HEADERS frame")
            type, len = header
            type == HT._H3_FRAME_HEADERS || error("expected a HEADERS frame")
            fields = HT._qpack_decode(HT._h3_read_payload(s, len, 1 << 16))
            path = ""
            for field in fields
                field.name == ":path" && (path = field.value)
            end
            path == "/h3-roundtrip" || error("expected /h3-roundtrip path")
            response = _http_trim_h3_frame(HT._H3_FRAME_HEADERS, HT._qpack_encode(HT.HeaderField[
                HT.HeaderField(":status", "200", false),
                HT.HeaderField("content-length", "12", false),
            ]))
            append!(response, _http_trim_h3_frame(HT._H3_FRAME_DATA, collect(codeunits("h3-roundtrip"))))
            write(s, response)
            closewrite(s)
            break
        end
        # Wait for the client to close the connection.
        Reseau.QUIC.accept_stream(conn)
    catch err
        err isa Reseau.QUIC.ConnectionError || rethrow()
    finally
        HTTP.@try_ignore close(conn)
    end
    return nothing
end

function run_http_trim_client_h3_roundtrip()::Nothing
    listener::Union{Nothing,Reseau.QUIC.Listener} = nothing
    server_task::Union{Nothing,Task} = nothing
    conn::Union{Nothing,HT.H3Connection} = nothing
    try
        server_config = Reseau.TLS.Config(verify_peer = false, cert_file = _HTTP_TRIM_H3_CERT, key_file = _HTTP_TRIM_H3_KEY, alpn_protocols = ["h3"])
        listener = Reseau.QUIC.listen(Reseau.UDP.loopback_addr(0), server_config)
        _HTTP_TRIM_H3_LISTENER[] = listener
        server_task = Task(_http_trim_h3_server_entry)
        schedule(server_task)
        port = Int((Reseau.QUIC.local_addr(listener::Reseau.QUIC.Listener)::Reseau.UDP.SocketAddrV4).port)
        address = "127.0.0.1:$(port)"
        conn = HT.connect_h3!(address; tls_config = Reseau.TLS.Config(verify_peer = false))
        request = HT.Request("GET", "/h3-roundtrip"; host = address, body = HT.EmptyBody(), content_length = 0)
        response = HT.h3_roundtrip!(conn::HT.H3Connection, request)
        response.status == 200 || error("expected 200 response, got $(response.status)")
        body = response.body
        body isa HT.H3Body || error("expected H3Body response body")
        trim_body_string(body::HT.H3Body) == "h3-roundtrip" || error("unexpected response body")
    finally
        HTTP.@try_ignore conn === nothing || close(conn::HT.H3Connection)
        _HTTP_TRIM_H3_LISTENER[] = nothing
        HTTP.@try_ignore listener === nothing || close(listener::Reseau.QUIC.Listener)
        HTTP.@try_ignore begin
            if server_task !== nothing
                wait(server_task)
            end
        end
        yield()
        GC.gc()
        HTTP.@try_ignore Reseau.IOPoll.shutdown!()
    end
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_http_trim_client_h3_roundtrip()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
