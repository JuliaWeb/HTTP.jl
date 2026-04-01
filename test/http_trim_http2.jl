include("trim_workload_common.jl")

function run_http_trim_http2()::Nothing
    # Desired future coverage once package-local background Tasks are trim-safe:
    #
    # server = HT.serve!("127.0.0.1", 0) do request
    #     trim_text_response("h2:" * request.target; proto_major = 2, proto_minor = 0)
    # end
    # client = HT.Client()
    # address = "127.0.0.1:$(trim_wait_value(() -> HT.port(server)))"
    # request = HT.Request("GET", "/h2"; host = address, body = HT.EmptyBody(), content_length = 0)
    # response = HT.do!(client, address, request; protocol = :h2)

    headers = HT.HeaderField[
        HT.HeaderField(":method", "GET", false),
        HT.HeaderField(":path", "/h2", false),
        HT.HeaderField(":scheme", "http", false),
        HT.HeaderField(":authority", "127.0.0.1:8080", false),
    ]
    encoder = HT.Encoder()
    block = HT.encode_header_block(encoder, headers)
    isempty(block) && error("expected non-empty HPACK header block")

    decoder = HT.Decoder()
    decoded = HT.decode_header_block(decoder, block)
    length(decoded) == length(headers) || error("unexpected decoded header count")
    for i in eachindex(headers)
        decoded[i].name == headers[i].name || error("unexpected decoded header name")
        decoded[i].value == headers[i].value || error("unexpected decoded header value")
    end

    io = IOBuffer()
    writer = io
    HT.write_frame!(writer, HT.SettingsFrame(false, Pair{UInt16,UInt32}[UInt16(0x1) => UInt32(4096)]))
    HT.write_frame!(writer, HT.HeadersFrame(UInt32(1), true, true, block))
    seekstart(io)

    reader = io
    settings = HT.read_frame!(reader)
    settings isa HT.SettingsFrame || error("expected SETTINGS frame")
    headers_frame = HT.read_frame!(reader)
    headers_frame isa HT.HeadersFrame || error("expected HEADERS frame")
    hf = headers_frame::HT.HeadersFrame
    hf.stream_id == UInt32(1) || error("unexpected HEADERS stream id")
    hf.end_stream || error("expected HEADERS end_stream")
    hf.end_headers || error("expected HEADERS end_headers")
    hf.header_block_fragment == block || error("unexpected HEADERS payload")
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_http_trim_http2()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
