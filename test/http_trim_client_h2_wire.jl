include("trim_workload_common.jl")

const _HTTP_TRIM_H2_WIRE_LISTENER = Ref{Union{Nothing,Reseau.TCP.Listener}}(nothing)
const _HTTP_TRIM_H2_WIRE_STARTED = Ref(false)
const _HTTP_TRIM_H2_WIRE_DONE = Ref(false)

function _http_trim_write_all_h2!(conn::Reseau.TCP.Conn, bytes::Vector{UInt8})::Nothing
    total = 0
    while total < length(bytes)
        n = write(conn, bytes[(total + 1):end])
        n > 0 || error("expected write progress")
        total += n
    end
    return nothing
end

function _http_trim_read_exact_h2!(conn::Reseau.TCP.Conn, n::Int)::Vector{UInt8}
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

function _http_trim_write_h2_frame!(conn::Reseau.TCP.Conn, frame::HT.AbstractFrame)::Nothing
    io = IOBuffer()
    framer = io
    HT.write_frame!(framer, frame)
    _http_trim_write_all_h2!(conn, take!(io))
    return nothing
end

function _http_trim_h2_wire_server_entry()::Nothing
    _HTTP_TRIM_H2_WIRE_STARTED[] = true
    listener = _HTTP_TRIM_H2_WIRE_LISTENER[]::Reseau.TCP.Listener
    conn = Reseau.TCP.accept(listener)
    try
        reader = HT._ConnReader(conn)
        decoder = HT.Decoder()
        encoder = HT.Encoder()

        _http_trim_read_exact_h2!(conn, length(HT._H2_PREFACE)) == HT._H2_PREFACE || error("unexpected client preface")
        client_settings = HT.read_frame!(reader)
        client_settings isa HT.SettingsFrame || error("expected client SETTINGS frame")
        (client_settings::HT.SettingsFrame).ack && error("unexpected SETTINGS ack from client")

        _http_trim_write_h2_frame!(conn, HT.SettingsFrame(false, Pair{UInt16,UInt32}[]))

        frame = HT.read_frame!(reader)
        frame isa HT.SettingsFrame || error("expected client SETTINGS ack")
        (frame::HT.SettingsFrame).ack || error("expected SETTINGS ack")

        request_headers = HT.read_frame!(reader)
        request_headers isa HT.HeadersFrame || error("expected client HEADERS frame")
        hf = request_headers::HT.HeadersFrame
        headers = HT.decode_header_block(decoder, hf.header_block_fragment)
        fields = Dict(field.name => field.value for field in headers)
        get(fields, ":method", nothing) == "GET" || error("expected GET request")
        get(fields, ":path", nothing) == "/h2-wire" || error("expected /h2-wire path")

        response_block = HT.encode_header_block(encoder, HT.HeaderField[
            HT.HeaderField(":status", "200", false),
            HT.HeaderField("content-length", "7", false),
            HT.HeaderField("content-type", "text/plain", false),
        ])
        _http_trim_write_h2_frame!(conn, HT.HeadersFrame(UInt32(1), false, true, response_block))
        _http_trim_write_h2_frame!(conn, HT.DataFrame(UInt32(1), true, collect(codeunits("h2-wire"))))
    finally
        _HTTP_TRIM_H2_WIRE_DONE[] = true
        HTTP.@try_ignore close(conn)
    end
    return nothing
end

function run_http_trim_client_h2_wire()::Nothing
    listener::Union{Nothing,Reseau.TCP.Listener} = nothing
    conn::Union{Nothing,Reseau.TCP.Conn} = nothing
    server_task::Union{Nothing,Task} = nothing
    try
        listener = Reseau.TCP.listen(Reseau.TCP.loopback_addr(0); backlog = 16)
        _HTTP_TRIM_H2_WIRE_LISTENER[] = listener
        _HTTP_TRIM_H2_WIRE_STARTED[] = false
        _HTTP_TRIM_H2_WIRE_DONE[] = false

        server_task = Task(_http_trim_h2_wire_server_entry)
        schedule(server_task)
        start_status = Reseau.IOPoll.timedwait(() -> _HTTP_TRIM_H2_WIRE_STARTED[], 5.0; pollint = 0.001)
        start_status == :timed_out && error("timed out waiting for trim H2 wire server task")

        addr = Reseau.TCP.addr(listener)::Reseau.TCP.SocketAddrV4
        address = "127.0.0.1:$(Int(addr.port))"
        conn = Reseau.TCP.connect(Reseau.TCP.loopback_addr(Int(addr.port)))
        reader = HT._ConnReader(conn)
        encoder = HT.Encoder()
        decoder = HT.Decoder()

        _http_trim_write_all_h2!(conn, HT._H2_PREFACE)
        _http_trim_write_h2_frame!(conn, HT.SettingsFrame(false, Pair{UInt16,UInt32}[]))

        server_settings = HT.read_frame!(reader)
        server_settings isa HT.SettingsFrame || error("expected server SETTINGS frame")
        (server_settings::HT.SettingsFrame).ack && error("unexpected SETTINGS ack from server")

        _http_trim_write_h2_frame!(conn, HT.SettingsFrame(true, Pair{UInt16,UInt32}[]))

        request = HT.Request("GET", "/h2-wire"; host = address, body = HT.EmptyBody(), content_length = 0)
        header_block = HT.encode_header_block(encoder, HT._request_headers_for_h2(address, request, false))
        _http_trim_write_h2_frame!(conn, HT.HeadersFrame(UInt32(1), true, true, header_block))

        response_headers = HT.read_frame!(reader)
        response_headers isa HT.HeadersFrame || error("expected response HEADERS frame")
        decoded_headers = HT.decode_header_block(decoder, (response_headers::HT.HeadersFrame).header_block_fragment)
        status, _ = HT._decode_response_headers(decoded_headers)
        status == 200 || error("expected 200 response, got $(status)")

        data_frame = HT.read_frame!(reader)
        data_frame isa HT.DataFrame || error("expected DATA frame")
        df = data_frame::HT.DataFrame
        df.end_stream || error("expected end_stream DATA frame")
        String(df.data) == "h2-wire" || error("unexpected DATA payload")
    finally
        _HTTP_TRIM_H2_WIRE_LISTENER[] = nothing
        HTTP.@try_ignore conn === nothing || close(conn::Reseau.TCP.Conn)
        HTTP.@try_ignore listener === nothing || close(listener::Reseau.TCP.Listener)
        HTTP.@try_ignore begin
            if server_task !== nothing
                done_status = Reseau.IOPoll.timedwait(() -> _HTTP_TRIM_H2_WIRE_DONE[] || istaskdone(server_task::Task), 5.0; pollint = 0.001)
                done_status == :timed_out && error("timed out waiting for trim H2 wire server task shutdown")
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
    run_http_trim_client_h2_wire()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
