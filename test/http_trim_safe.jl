using HTTP
using Reseau

const HT = HTTP

mutable struct _TrimChunkConn
    payload::Vector{UInt8}
    idx::Int
    max_chunk::Int
end

function _TrimChunkConn(payload::Vector{UInt8}; max_chunk::Integer = 8)
    max_chunk > 0 || error("max_chunk must be > 0")
    return _TrimChunkConn(payload, 1, Int(max_chunk))
end

function Base.read!(conn::_TrimChunkConn, dst::Vector{UInt8})::Int
    conn.idx > length(conn.payload) && return 0
    n = min(length(dst), conn.max_chunk, length(conn.payload) - conn.idx + 1)
    copyto!(dst, 1, conn.payload, conn.idx, n)
    conn.idx += n
    return n
end

function Base.readbytes!(
        conn::_TrimChunkConn,
        dst::AbstractVector{UInt8},
        nb::Integer = length(dst);
        all::Bool = true,
    )::Int
    isempty(dst) && return 0
    requested = min(length(dst), Int(nb))
    requested < 0 && throw(ArgumentError("nb must be >= 0"))
    requested == 0 && return 0
    total = 0
    while total < requested
        conn.idx > length(conn.payload) && break
        n = min(requested - total, conn.max_chunk, length(conn.payload) - conn.idx + 1)
        copyto!(dst, total + 1, conn.payload, conn.idx, n)
        conn.idx += n
        total += n
        !all && break
    end
    return total
end

function run_http_trim_sample()::Nothing
    headers = HT.Headers()
    HT.setheader(headers, "content-type", "application/json")
    HT.appendheader(headers, "x-trace-id", "abc")
    HT.appendheader(headers, "x-trace-id", "def")
    HT.headercontains(headers, "x-trace-id", "abc") || error("expected token")
    ctx = HT.RequestContext(deadline_ns = time_ns() + 1_000_000)
    req = HT.Request("GET", "/health"; headers = headers, context = ctx)
    _ = req
    body = HT.BytesBody(UInt8[0x61, 0x62, 0x63])
    resp = HT.Response{typeof(body)}(200, "OK", headers, HT.Headers(), body, Int64(-1), UInt8(1), UInt8(1), false, nothing, nothing, nothing, 0)
    _ = resp
    dst = Vector{UInt8}(undef, 3)
    n = HT.body_read!(body, dst)
    n == 3 || error("expected full body read")
    dst == UInt8[0x61, 0x62, 0x63] || error("unexpected bytes")
    HT.body_close!(body)
    HT.body_closed(body) || error("expected closed body")
    req = HT.Request("POST", "/ready"; headers = headers, body = HT.BytesBody(UInt8[0x61, 0x62]), content_length = 2)
    req_io = IOBuffer()
    HT.write_request!(req_io, req)
    req_bytes = take!(req_io)
    isempty(req_bytes) && error("expected serialized request bytes")
    parsed_req = HT.read_request(IOBuffer(req_bytes))::HT.Request{HT.FixedLengthBody{IOBuffer}}
    req_body_buf = Vector{UInt8}(undef, 2)
    HT.body_read!(parsed_req.body, req_body_buf) == 2 || error("expected parsed request body")
    resp_headers = HT.Headers()
    HT.setheader(resp_headers, "Transfer-Encoding", "chunked")
    resp_trailers = HT.Headers()
    HT.setheader(resp_trailers, "X-Trim", "1")
    resp_body = HT.BytesBody(UInt8[0x6f, 0x6b])
    resp = HT.Response{typeof(resp_body)}(200, "OK", resp_headers, resp_trailers, resp_body, Int64(-1), UInt8(1), UInt8(1), false, req, nothing, nothing, 0)
    resp_io = IOBuffer()
    HT.write_response!(resp_io, resp)
    resp_bytes = take!(resp_io)
    isempty(resp_bytes) && error("expected serialized response bytes")
    parsed_resp = HT._read_response(IOBuffer(resp_bytes), parsed_req)::HT.Response{HT.ChunkedBody{IOBuffer}}
    resp_body_buf = Vector{UInt8}(undef, 2)
    HT.body_read!(parsed_resp.body, resp_body_buf) == 2 || error("expected parsed response body")
    chunk_conn = _TrimChunkConn(resp_bytes; max_chunk = 3)
    chunk_reader = HT._ConnReader(chunk_conn; buffer_bytes = 16)
    parsed_resp_chunked = HT._read_response(chunk_reader, parsed_req)::HT.Response{HT.ChunkedBody{HT._ConnReader{_TrimChunkConn}}}
    chunk_body_buf = Vector{UInt8}(undef, 2)
    HT.body_read!(parsed_resp_chunked.body, chunk_body_buf) == 2 || error("expected parsed chunked response body")
    h2_frame_io = IOBuffer()
    h2_writer = HT.Framer(h2_frame_io)
    HT.write_frame!(h2_writer, HT.PingFrame(false, (UInt8(1), UInt8(2), UInt8(3), UInt8(4), UInt8(5), UInt8(6), UInt8(7), UInt8(8))))
    h2_bytes = take!(h2_frame_io)
    h2_reader = HT.Framer(HT._ConnReader(_TrimChunkConn(h2_bytes; max_chunk = 2); buffer_bytes = 8))
    h2_frame = HT.read_frame!(h2_reader)
    h2_frame isa HT.PingFrame || error("expected parsed HTTP/2 PING frame")
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_http_trim_sample()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
