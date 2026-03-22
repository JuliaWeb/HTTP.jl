using Test
using HTTP
using Reseau

const HT = HTTP

function _read_all_body_bytes(body::HT.AbstractBody)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 8)
    while true
        n = HT.body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    return out
end

mutable struct _TestStreamingBody <: HT.AbstractBody
    data::Vector{UInt8}
    next_index::Int
    closed::Bool
end

function _TestStreamingBody(data::AbstractString)
    return _TestStreamingBody(collect(codeunits(String(data))), 1, false)
end

function HT.body_closed(body::_TestStreamingBody)::Bool
    return body.closed
end

function HT.body_close!(body::_TestStreamingBody)
    body.closed = true
    return nothing
end

function HT.body_read!(body::_TestStreamingBody, dst::Vector{UInt8})::Int
    body.closed && return 0
    isempty(dst) && return 0
    available = (length(body.data) - body.next_index) + 1
    available <= 0 && return 0
    n = min(length(dst), available)
    copyto!(dst, 1, body.data, body.next_index, n)
    body.next_index += n
    return n
end

@testset "HTTP/1 request parse/write" begin
    raw = "POST /upload HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\nX-Test: one\r\nX-Test: two\r\n\r\nhello"
    req = HT.read_request(IOBuffer(codeunits(raw)))
    @test req.method == "POST"
    @test req.target == "/upload"
    @test req.host == "example.com"
    @test req.content_length == 5
    @test HT.headers(req.headers, "X-Test") == ["one, two"]
    @test _read_all_body_bytes(req.body) == collect(codeunits("hello"))
    headers = HT.Headers()
    HT.setheader(headers, "host", "example.com")
    body = HT.BytesBody(collect(codeunits("ping")))
    outbound = HT.Request("PUT", "/v1"; headers = headers, body = body, content_length = 4)
    io = IOBuffer()
    HT.write_request!(io, outbound)
    parsed = HT.read_request(IOBuffer(take!(io)))
    @test parsed.method == "PUT"
    @test parsed.target == "/v1"
    @test parsed.content_length == 4
    @test _read_all_body_bytes(parsed.body) == collect(codeunits("ping"))

    function make_streaming_request()
        headers = HT.Headers()
        HT.setheader(headers, "host", "example.com")
        payload = collect(codeunits("streaming-body"))
        return HT.Request("PUT", "/stream"; headers = headers, body = HT.BytesBody(payload), content_length = length(payload))
    end
    expected_io = IOBuffer()
    HT.write_request!(expected_io, make_streaming_request())
    streamed_io = IOBuffer()
    request_buf = IOBuffer()
    HT._write_request_streaming!(request_buf, streamed_io, make_streaming_request())
    @test take!(streamed_io) == take!(expected_io)

    partial_body = HT.BytesBody(collect(codeunits("abcdef")))
    advance_buf = Vector{UInt8}(undef, 2)
    @test HT.body_read!(partial_body, advance_buf) == 2
    partial_io = IOBuffer()
    HT._write_exact_bytes_body!(partial_io, partial_body, 4)
    @test take!(partial_io) == collect(codeunits("cdef"))
end

@testset "HTTP/1 header serialization preserves stored entries" begin
    headers = HT.Headers()
    push!(headers, "X-Test" => "one")
    push!(headers, "X-Test" => "two")
    push!(headers, "Set-Cookie" => "a=1")
    push!(headers, "Set-Cookie" => "b=2")
    io = IOBuffer()
    HT._write_headers!(io, headers)
    @test String(take!(io)) == "X-Test: one\r\nX-Test: two\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n"
end

@testset "HTTP/1 header serialization hardening" begin
    request_headers = HT.Headers()
    HT.setheader(request_headers, "Host", "example.com")
    push!(request_headers, "X-Test" => "ok\r\nInjected: yes")
    request = HT.Request("GET", "/"; headers = request_headers, body = HT.EmptyBody(), content_length = 0)
    request_io = IOBuffer()
    HT.write_request!(request_io, request)
    request_wire = String(take!(request_io))
    @test occursin("X-Test: ok  Injected: yes\r\n", request_wire)
    @test !occursin("\r\nInjected: yes\r\n", request_wire)

    response_headers = HT.Headers()
    push!(response_headers, "X-Test" => "\r\n value ")
    response = HT.Response(200; headers = response_headers, body = HT.EmptyBody(), content_length = 0)
    response_io = IOBuffer()
    HT.write_response!(response_io, response)
    response_wire = String(take!(response_io))
    @test occursin("X-Test: value\r\n", response_wire)
    @test !occursin("\r\n value\r\n", response_wire)

    invalid_name_headers = HT.Headers()
    push!(invalid_name_headers, "Bad Header" => "value")
    @test_throws HT.ProtocolError HT._write_headers!(IOBuffer(), invalid_name_headers)

    invalid_value_headers = HT.Headers()
    push!(invalid_value_headers, "X-Test" => "bad\0value")
    @test_throws HT.ProtocolError HT._write_headers!(IOBuffer(), invalid_value_headers)

    declared_bad_trailer_headers = HT.Headers()
    HT.setheader(declared_bad_trailer_headers, "Transfer-Encoding", "chunked")
    HT.setheader(declared_bad_trailer_headers, "Trailer", "Content-Length")
    declared_bad_trailer = HT.Response(200; headers = declared_bad_trailer_headers, body = HT.BytesBody(collect(codeunits("body"))), content_length = -1)
    @test_throws HT.ProtocolError HT.write_response!(IOBuffer(), declared_bad_trailer)

    invalid_trailer_headers = HT.Headers()
    HT.setheader(invalid_trailer_headers, "Transfer-Encoding", "chunked")
    invalid_trailers = HT.Headers()
    HT.setheader(invalid_trailers, "Content-Length", "5")
    invalid_trailer_response = HT.Response(200; headers = invalid_trailer_headers, trailers = invalid_trailers, body = HT.BytesBody(collect(codeunits("body"))), content_length = -1)
    @test_throws HT.ProtocolError HT.write_response!(IOBuffer(), invalid_trailer_response)
end

@testset "HTTP/1 response parse/write chunked" begin
    raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Trailer: done\r\n\r\n"
    resp = HT._read_response(IOBuffer(codeunits(raw)))
    @test resp.status == 200
    @test HT.header(resp.headers, "Transfer-Encoding") == "chunked"
    @test _read_all_body_bytes(resp.body) == collect(codeunits("Wikipedia"))
    @test HT.header(resp.trailers, "X-Trailer") == "done"
    headers = HT.Headers()
    HT.setheader(headers, "Transfer-Encoding", "chunked")
    trailers = HT.Headers()
    HT.setheader(trailers, "X-Checksum", "abc123")
    resp_out = HT.Response(200; reason = "OK", headers = headers, trailers = trailers, body = HT.BytesBody(collect(codeunits("chunked-body"))), content_length = -1)
    io = IOBuffer()
    HT.write_response!(io, resp_out)
    resp_in = HT._read_response(IOBuffer(take!(io)))
    @test resp_in.status == 200
    @test _read_all_body_bytes(resp_in.body) == collect(codeunits("chunked-body"))
    @test HT.header(resp_in.trailers, "X-Checksum") == "abc123"
end

@testset "HTTP/1 serializes custom abstract bodies" begin
    headers = HT.Headers()
    HT.setheader(headers, "host", "example.com")
    request = HT.Request("POST", "/custom"; headers = headers, body = _TestStreamingBody("payload"), content_length = 7)
    request_io = IOBuffer()
    HT.write_request!(request_io, request)
    parsed_request = HT.read_request(IOBuffer(take!(request_io)))
    @test _read_all_body_bytes(parsed_request.body) == collect(codeunits("payload"))

    response_headers = HT.Headers()
    HT.setheader(response_headers, "Transfer-Encoding", "chunked")
    response_trailers = HT.Headers()
    HT.setheader(response_trailers, "X-Custom", "yes")
    response = HT.Response(200; headers = response_headers, trailers = response_trailers, body = _TestStreamingBody("stream"), content_length = -1)
    response_io = IOBuffer()
    HT.write_response!(response_io, response)
    parsed_response = HT._read_response(IOBuffer(take!(response_io)))
    @test _read_all_body_bytes(parsed_response.body) == collect(codeunits("stream"))
    @test HT.header(parsed_response.trailers, "X-Custom") == "yes"
end

@testset "HTTP/1 parse and framing errors" begin
    bad_header = "GET / HTTP/1.1\r\nHost example.com\r\n\r\n"
    @test_throws HT.ParseError HT.read_request(IOBuffer(codeunits(bad_header)))
    bad_cl = "POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello"
    @test_throws HT.ProtocolError HT.read_request(IOBuffer(codeunits(bad_cl)))
    bad_chunk = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nX\r\nabc\r\n0\r\n\r\n"
    bad_resp = HT._read_response(IOBuffer(codeunits(bad_chunk)))
    @test_throws HT.ParseError _read_all_body_bytes(bad_resp.body)

    equal_cl = "POST /upload HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello"
    equal_req = HT.read_request(IOBuffer(codeunits(equal_cl)))
    @test equal_req.content_length == 5
    @test HT.headers(equal_req.headers, "Content-Length") == ["5"]
    @test _read_all_body_bytes(equal_req.body) == collect(codeunits("hello"))

    bad_te = "POST /upload HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: gzip\r\n\r\nhello"
    @test_throws HT.ProtocolError HT.read_request(IOBuffer(codeunits(bad_te)))

    dup_te = "POST /upload HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
    @test_throws HT.ProtocolError HT.read_request(IOBuffer(codeunits(dup_te)))

    bad_host_space = "GET / HTTP/1.1\r\nHost : example.com\r\n\r\n"
    @test_throws HT.ParseError HT.read_request(IOBuffer(codeunits(bad_host_space)))

    missing_host = "GET / HTTP/1.1\r\nConnection: close\r\n\r\n"
    @test_throws HT.ProtocolError HT.read_request(IOBuffer(codeunits(missing_host)))

    dup_host = "GET / HTTP/1.1\r\nHost: example.com\r\nHost: example.com\r\n\r\n"
    @test_throws HT.ProtocolError HT.read_request(IOBuffer(codeunits(dup_host)))

    malformed_host = "GET / HTTP/1.1\r\nHost: example.com/path\r\n\r\n"
    @test_throws HT.ProtocolError HT.read_request(IOBuffer(codeunits(malformed_host)))

    bad_target = "GET foo HTTP/1.1\r\nHost: example.com\r\n\r\n"
    @test_throws HT.ParseError HT.read_request(IOBuffer(codeunits(bad_target)))

    stale_cl_chunked = "POST /upload HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
    stale_req = HT.read_request(IOBuffer(codeunits(stale_cl_chunked)))
    @test stale_req.content_length == -1
    @test !HT.hasheader(stale_req.headers, "Content-Length")
    forwarded = IOBuffer()
    HT.write_request!(forwarded, stale_req)
    forwarded_wire = String(take!(forwarded))
    @test occursin("Transfer-Encoding: chunked\r\n", forwarded_wire)
    @test !occursin("Content-Length:", forwarded_wire)

    stale_resp_headers = HT.Headers()
    HT.setheader(stale_resp_headers, "Transfer-Encoding", "chunked")
    HT.setheader(stale_resp_headers, "Content-Length", "5")
    stale_resp = HT.Response(200; headers = stale_resp_headers, body = HT.BytesBody(collect(codeunits("hello"))), content_length = -1)
    response_io = IOBuffer()
    HT.write_response!(response_io, stale_resp)
    response_wire = String(take!(response_io))
    @test occursin("Transfer-Encoding: chunked\r\n", response_wire)
    @test !occursin("Content-Length:", response_wire)
end

@testset "HTTP/1 response body suppression" begin
    raw = "HTTP/1.1 204 No Content\r\nContent-Length: 5\r\n\r\nhello"
    resp = HT._read_response(IOBuffer(codeunits(raw)))
    @test resp.status == 204
    @test _read_all_body_bytes(resp.body) == UInt8[]
end

@testset "HTTP/1 status line reason phrase handling" begin
    response = HT.Response(200; body = HT.EmptyBody(), content_length = 0)
    io = IOBuffer()
    HT.write_response!(io, response)
    bytes = take!(io)
    text = String(copy(bytes))
    @test startswith(text, "HTTP/1.1 200 OK\r\n")

    parsed = HT._read_response(IOBuffer(bytes))
    @test parsed.status == 200
    @test parsed.reason == "OK"

    # Parser accepts empty reason phrases from peers.
    raw = "HTTP/1.1 299 \r\nContent-Length: 0\r\n\r\n"
    parsed_raw = HT._read_response(IOBuffer(codeunits(raw)))
    @test parsed_raw.status == 299
    @test parsed_raw.reason == ""
end
