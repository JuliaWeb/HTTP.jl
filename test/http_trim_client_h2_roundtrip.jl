include("trim_workload_common.jl")

const _HTTP_TRIM_H2_ROUNDTRIP_LISTENER = Ref{Union{Nothing,Reseau.TCP.Listener}}(nothing)
const _HTTP_TRIM_H2_ROUNDTRIP_STARTED = Ref(false)
const _HTTP_TRIM_H2_ROUNDTRIP_DONE = Ref(false)

function _http_trim_h2_roundtrip_write_all!(conn::Reseau.TCP.Conn, bytes::Vector{UInt8})::Nothing
    total = 0
    while total < length(bytes)
        n = write(conn, bytes[(total + 1):end])
        n > 0 || error("expected write progress")
        total += n
    end
    return nothing
end

function _http_trim_h2_roundtrip_read_exact!(conn::Reseau.TCP.Conn, n::Int)::Vector{UInt8}
    out = Vector{UInt8}(undef, n)
    offset = 0
    while offset < n
        chunk = Vector{UInt8}(undef, n - offset)
        nr = readbytes!(conn, chunk)
        nr > 0 || error("unexpected EOF")
        copyto!(out, offset + 1, chunk, 1, nr)
        offset += nr
    end
    return out
end

function _http_trim_h2_roundtrip_write_frame!(conn::Reseau.TCP.Conn, frame::HT.AbstractFrame)::Nothing
    io = IOBuffer()
    framer = io
    HT.write_frame!(framer, frame)
    _http_trim_h2_roundtrip_write_all!(conn, take!(io))
    return nothing
end

function _http_trim_h2_roundtrip_next_headers!(reader::IO)::HT.HeadersFrame
    while true
        frame = HT.read_frame!(reader)
        frame isa HT.HeadersFrame && return frame::HT.HeadersFrame
        frame isa HT.SettingsFrame && continue
        frame isa HT.WindowUpdateFrame && continue
        frame isa HT.PingFrame && continue
        error("expected HEADERS frame, got $(typeof(frame))")
    end
end

function _http_trim_h2_roundtrip_server_entry()::Nothing
    _HTTP_TRIM_H2_ROUNDTRIP_STARTED[] = true
    listener = _HTTP_TRIM_H2_ROUNDTRIP_LISTENER[]::Reseau.TCP.Listener
    conn = Reseau.TCP.accept(listener)
    try
        reader = HT._ConnReader(conn)
        decoder = HT.Decoder()
        encoder = HT.Encoder()

        _http_trim_h2_roundtrip_read_exact!(conn, length(HT._H2_PREFACE)) == HT._H2_PREFACE || error("unexpected client preface")
        client_settings = HT.read_frame!(reader)
        client_settings isa HT.SettingsFrame || error("expected client SETTINGS frame")
        _http_trim_h2_roundtrip_write_frame!(conn, HT.SettingsFrame(false, Pair{UInt16,UInt32}[]))

        ack = HT.read_frame!(reader)
        ack isa HT.SettingsFrame || error("expected client SETTINGS ack")
        (ack::HT.SettingsFrame).ack || error("expected SETTINGS ack")

        headers_frame = _http_trim_h2_roundtrip_next_headers!(reader)
        decoded_headers = HT.decode_header_block(decoder, headers_frame.header_block_fragment)
        fields = Dict(field.name => field.value for field in decoded_headers)
        get(fields, ":method", nothing) == "GET" || error("expected GET request")
        get(fields, ":path", nothing) == "/h2-roundtrip" || error("expected /h2-roundtrip path")

        response_block = HT.encode_header_block(encoder, HT.HeaderField[
            HT.HeaderField(":status", "200", false),
            HT.HeaderField("content-length", "12", false),
            HT.HeaderField("content-type", "text/plain", false),
        ])
        _http_trim_h2_roundtrip_write_frame!(conn, HT.HeadersFrame(UInt32(1), false, true, response_block))
        _http_trim_h2_roundtrip_write_frame!(conn, HT.DataFrame(UInt32(1), true, collect(codeunits("h2-roundtrip"))))
    finally
        _HTTP_TRIM_H2_ROUNDTRIP_DONE[] = true
        try
            close(conn)
        catch
        end
    end
    return nothing
end

function run_http_trim_client_h2_roundtrip()::Nothing
    listener::Union{Nothing,Reseau.TCP.Listener} = nothing
    server_task::Union{Nothing,Task} = nothing
    conn::Union{Nothing,HT.H2Connection} = nothing
    try
        listener = Reseau.TCP.listen(Reseau.TCP.loopback_addr(0); backlog = 16)
        _HTTP_TRIM_H2_ROUNDTRIP_LISTENER[] = listener
        _HTTP_TRIM_H2_ROUNDTRIP_STARTED[] = false
        _HTTP_TRIM_H2_ROUNDTRIP_DONE[] = false

        server_task = Task(_http_trim_h2_roundtrip_server_entry)
        schedule(server_task)
        start_status = Reseau.IOPoll.timedwait(() -> _HTTP_TRIM_H2_ROUNDTRIP_STARTED[], 5.0; pollint = 0.001)
        start_status == :timed_out && error("timed out waiting for trim H2 roundtrip server task")

        addr = Reseau.TCP.addr(listener)::Reseau.TCP.SocketAddrV4
        address = "127.0.0.1:$(Int(addr.port))"

        conn = HT.connect_h2!(address; secure = false)
        request = HT.Request("GET", "/h2-roundtrip"; host = address, body = HT.EmptyBody(), content_length = 0)
        response = HT.h2_roundtrip!(conn, request)
        response.status == 200 || error("expected 200 response, got $(response.status)")
        body = response.body
        body isa HT.H2Body || error("expected H2Body response body")
        trim_body_string(body::HT.H2Body) == "h2-roundtrip" || error("unexpected response body")
    finally
        try
            conn === nothing || close(conn::HT.H2Connection)
        catch
        end
        _HTTP_TRIM_H2_ROUNDTRIP_LISTENER[] = nothing
        try
            listener === nothing || close(listener::Reseau.TCP.Listener)
        catch
        end
        try
            if server_task !== nothing
                done_status = Reseau.IOPoll.timedwait(() -> _HTTP_TRIM_H2_ROUNDTRIP_DONE[] || istaskdone(server_task::Task), 5.0; pollint = 0.001)
                done_status == :timed_out && error("timed out waiting for trim H2 roundtrip server task shutdown")
                wait(server_task)
            end
        catch
        end
        yield()
        GC.gc()
        try
            Reseau.IOPoll.shutdown!()
        catch
        end
    end
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_http_trim_client_h2_roundtrip()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
