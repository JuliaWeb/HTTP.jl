using Test
using HTTP
using Reseau

const HT = HTTP

function _read_all_form_body(body::HT.AbstractBody)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 16)
    while true
        n = HT.body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    return out
end

struct _UnsupportedRequestBody end

function _multipart_fixture_body()::Vector{UInt8}
    return Vector{UInt8}(join([
        "----------------------------918073721150061572809433",
        "Content-Disposition: form-data; name=\"namevalue\"; filename=\"multipart.txt\"",
        "Content-Type: text/plain",
        "",
        "not much to say",
        "----------------------------918073721150061572809433",
        "Content-Disposition: form-data; name=\"key1\"",
        "",
        "1",
        "----------------------------918073721150061572809433--",
        "",
    ], "\r\n"))
end

function _multipart_extended_fixture_body()::Vector{UInt8}
    return Vector{UInt8}(join([
        "----------------------------918073721150061572809433",
        "Content-Disposition: form-data; name=\"namevalue\"; filename=\"multipart.txt\"",
        "Content-Type: text/plain",
        "",
        "not much to say",
        "----------------------------918073721150061572809433",
        "Content-Disposition: form-data; name=\"key1\"",
        "",
        "1",
        "----------------------------918073721150061572809433",
        "Content-Disposition: form-data; name=\"json_file\"; filename=\"payload.json\"",
        "Content-Type: application/json",
        "",
        "{\"data\": [\"this is json data\"]}",
        "----------------------------918073721150061572809433",
        "content-type: text/plain",
        "content-disposition: form-data; name=\"key3\"",
        "",
        "This file has lower-cased content- keys, and disposition comes second.",
        "----------------------------918073721150061572809433--",
        "",
    ], "\r\n"))
end

@testset "HTTP forms and sniff helpers" begin
    form = HT.Form(Dict("text" => "hello"))
    @test startswith(HT.content_type(form), "multipart/form-data; boundary=")
    mark(form)
    payload = read(form)
    payload_text = String(copy(payload))
    reset(form)
    @test occursin("Content-Disposition: form-data; name=\"text\"", payload_text)
    @test occursin("hello", payload_text)
    @test read(form) == payload

    multipart = HT.Multipart(nothing, IOBuffer("some data"), "text/plain", "", "testname")
    shown = sprint(show, multipart)
    @test occursin("contenttype=\"text/plain\"", shown)
    @test HT.Multipart(nothing, IOBuffer("bytes")) isa HT.Multipart
    @test_throws MethodError HT.Multipart(nothing, "bytes", "text/plain", "", "testname")

    @test HT.Form(Dict(); boundary = "a") isa HT.Form
    @test HT.Form(Dict(); boundary = " Aa1'()+,-.:=?") isa HT.Form
    @test HT.Form(Dict(); boundary = 'a'^70) isa HT.Form
    @test_throws AssertionError HT.Form(Dict(); boundary = "")
    @test_throws AssertionError HT.Form(Dict(); boundary = 'a'^71)
    @test_throws AssertionError HT.Form(Dict(); boundary = "a ")

    body = _multipart_fixture_body()
    parsed = HT.parse_multipart_form(
        "multipart/form-data; boundary=--------------------------918073721150061572809433",
        body,
    )
    @test parsed !== nothing
    @test length(parsed::Vector) == 2
    @test parsed[1].name == "namevalue"
    @test parsed[1].filename == "multipart.txt"
    @test String(read(parsed[1])) == "not much to say"
    @test parsed[2].name == "key1"
    @test String(read(parsed[2])) == "1"

    @test HT.sniff(IOBuffer("Hello world")) == "text/plain; charset=utf-8"
    @test HT.sniff(IOBuffer("{\"a\":1}")) == "application/json; charset=utf-8"
end

@testset "HTTP sniff coverage cases" begin
    sniff_cases = [
        (UInt8[], "text/plain; charset=utf-8"),
        (UInt8[0x01, 0x02, 0x03], "application/octet-stream"),
        (collect(codeunits("<HTML></HTML>")), "text/html; charset=utf-8"),
        (collect(codeunits("   <!DOCTYPE HTML>...")), "text/html; charset=utf-8"),
        (collect(codeunits("\n<?xml!")), "text/xml; charset=utf-8"),
        (collect(codeunits("GIF87a")), "image/gif"),
        (collect(codeunits("GIF89a...")), "image/gif"),
        (UInt8[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "image/png"),
        (UInt8[0xFF, 0xD8, 0xFF], "image/jpeg"),
        (UInt8['R', 'I', 'F', 'F', 0x2c, 0x00, 0x00, 0x00, 'W', 'A', 'V', 'E'], "audio/wave"),
        (UInt8['R', 'I', 'F', 'F', 0x2c, 0x00, 0x00, 0x00, 'A', 'V', 'I', ' '], "video/avi"),
        (UInt8[0x00, 0x00, 0x00, 0x18, 'f', 't', 'y', 'p', 'm', 'p', '4', '2', 0x00, 0x00, 0x00, 0x00, 'm', 'p', '4', '2', 'i', 's', 'o', 'm'], "video/mp4"),
        (UInt8[0x50, 0x4B, 0x03, 0x04], "application/zip"),
        (UInt8[0x1F, 0x8B, 0x08], "application/x-gzip"),
    ]
    for (payload, expected) in sniff_cases
        @test HT.sniff(payload) == expected
        @test HT.sniff(IOBuffer(payload)) == expected
    end

    json_cases = [
        "null",
        "true",
        "false",
        "\"sample string \\\" with escaped double quote\"",
        "[1,2,3]",
        "{\"a\": -1.0}",
        "[ \"simple array\" , {\"key\": null } , { \"key2\" : false } ]",
    ]
    for json in json_cases
        @test HT.sniff(IOBuffer(json)) == "application/json; charset=utf-8"
    end
end

@testset "HTTP multipart parsing extended cases" begin
    body = _multipart_extended_fixture_body()
    parsed = HT.parse_multipart_form(
        "multipart/form-data; boundary=--------------------------918073721150061572809433",
        body,
    )
    @test parsed !== nothing
    parts = parsed::Vector
    @test length(parts) == 4

    @test parts[1].name == "namevalue"
    @test parts[1].filename == "multipart.txt"
    @test parts[1].contenttype == "text/plain"
    @test String(read(parts[1])) == "not much to say"

    @test parts[2].name == "key1"
    @test parts[2].filename === nothing
    @test parts[2].contenttype == "text/plain"
    @test String(read(parts[2])) == "1"

    @test parts[3].name == "json_file"
    @test parts[3].filename == "payload.json"
    @test parts[3].contenttype == "application/json"
    @test String(read(parts[3])) == "{\"data\": [\"this is json data\"]}"

    @test parts[4].name == "key3"
    @test parts[4].filename === nothing
    @test parts[4].contenttype == "text/plain"
    @test String(read(parts[4])) == "This file has lower-cased content- keys, and disposition comes second."

    @test HT.parse_multipart_form("text/plain", body) === nothing
    @test HT.parse_multipart_form(nothing, body) === nothing
    @test HT.parse_multipart_form("multipart/form-data; boundary=--------------------------918073721150061572809433", nothing) === nothing
end

@testset "parse_multipart_form(request) overload" begin
    form = HT.Form(Dict("alpha" => "1", "beta" => "two words"))
    body_bytes = read(form)
    ct = HT.content_type(form)
    request = HT.Request(
        "POST",
        "/upload";
        headers=["Content-Type" => ct],
        body=body_bytes,
    )
    parts = HT.parse_multipart_form(request)
    @test parts !== nothing
    @test length(parts) == 2
    names = sort(String[p.name for p in parts])
    @test names == ["alpha", "beta"]

    plain_request = HT.Request("POST", "/upload"; headers=["Content-Type" => "text/plain"], body="hi")
    @test HT.parse_multipart_form(plain_request) === nothing

    empty_request = HT.Request("GET", "/upload")
    @test HT.parse_multipart_form(empty_request) === nothing
end

@testset "HTTP request body helpers" begin
    string_bytes, string_content_type = HT._materialize_request_body_bytes("hello")
    @test string_bytes isa Base.CodeUnits{UInt8, String}
    @test String(string_bytes) == "hello"
    @test string_content_type === nothing

    raw = UInt8[0x61, 0x62, 0x63]
    raw_view = @view(raw[2:3])
    view_bytes, view_content_type = HT._materialize_request_body_bytes(raw_view)
    @test view_bytes === raw_view
    @test view_content_type === nothing

    bytes, content_type = HT._materialize_request_body_bytes(Dict("name" => "value with spaces"))
    @test String(bytes) == "name=value+with+spaces"   # x-www-form-urlencoded: SP -> '+' (#1138)
    @test content_type == "application/x-www-form-urlencoded"

    # SP serializes as '+', while a literal '+' (and '&', '=') stays percent-encoded,
    # so application/x-www-form-urlencoded round-trips unambiguously (#1138).
    @test String(HT._form_urlencode(Dict("k" => "a +b&c=d"))) == "k=a+%2Bb%26c%3Dd"

    bytes_named, content_type_named = HT._materialize_request_body_bytes((name = "value",))
    @test String(bytes_named) == "name=value"
    @test content_type_named == "application/x-www-form-urlencoded"

    form = HT.Form(Dict("field" => "value"))
    bytes_form, content_type_form = HT._materialize_request_body_bytes(form)
    @test startswith(content_type_form::String, "multipart/form-data; boundary=")
    @test occursin("field", String(bytes_form))

    iterable_body = HT._iterable_body(["hey", " there ", "sailor"])
    @test String(_read_all_form_body(iterable_body)) == "hey there sailor"

    io_body = HT._streaming_io_body(IOBuffer("stream body"))
    @test String(_read_all_form_body(io_body)) == "stream body"

    normalized_view = HT._normalize_body_input(raw_view)
    @test normalized_view.body isa HT.BytesBody
    @test normalized_view.body.data === raw_view
    @test normalized_view.content_length == 2
    @test normalized_view.replayable

    normalized = HT._normalized_request_body(HT.BytesBody(UInt8[0x61]), 1; default_content_type = "text/plain", replayable = true)
    @test normalized.body isa HT.BytesBody
    @test normalized.content_length == 1
    @test normalized.default_content_type == "text/plain"
    @test normalized.replayable

    io_bytes, io_content_type = HT._materialize_request_body_bytes(IOBuffer("streamed"))
    @test String(io_bytes) == "streamed"
    @test io_content_type === nothing
    @test_throws ArgumentError HT._materialize_request_body_bytes(42)

    @test isempty(HT._normalize_body_chunk(nothing))
    @test String(HT._normalize_body_chunk(IOBuffer("chunked"))) == "chunked"
    @test String(HT._normalize_body_chunk((name = "value",))) == "name=value"
    @test_throws ArgumentError HT._normalize_body_chunk(42)

    buffered_io = HT._normalize_body_input(IOBuffer("buffered-body"))
    @test buffered_io.body isa HT.BytesBody
    @test buffered_io.content_length == 13
    @test buffered_io.replayable
    @test String(_read_all_form_body(buffered_io.body)) == "buffered-body"

    streamed_io = Base.BufferStream()
    write(streamed_io, "streamed-body")
    closewrite(streamed_io)
    normalized_stream = HT._normalize_body_input(streamed_io)
    @test normalized_stream.body isa HT.CallbackBody
    @test normalized_stream.content_length == -1
    @test !normalized_stream.replayable
    @test String(_read_all_form_body(normalized_stream.body)) == "streamed-body"

    bytes_body = HT.BytesBody(UInt8[0x61, 0x62, 0x63])
    bytes_body.next_index = 3
    normalized_bytes_body = HT._normalize_body_input(bytes_body)
    @test normalized_bytes_body.body isa HT.BytesBody
    @test normalized_bytes_body.content_length == 1
    @test normalized_bytes_body.replayable
    @test String(_read_all_form_body(normalized_bytes_body.body)) == "c"

    normalized_iterable = HT._normalize_body_input(Any[nothing, "a", UInt8[0x62], Dict("c" => "d"), IOBuffer("!"), HT.EmptyBody(), HT.BytesBody(UInt8[0x65])])
    @test normalized_iterable.body isa HT.CallbackBody
    @test normalized_iterable.content_length == -1
    @test !normalized_iterable.replayable
    @test String(_read_all_form_body(normalized_iterable.body)) == "abc=d!e"

    custom_body = HT.CallbackBody(
        dst -> begin
            isempty(dst) && return 0
            dst[1] = 0x7a
            return 1
        end,
        () -> nothing,
    )
    normalized_custom = HT._normalize_body_input(custom_body)
    @test normalized_custom.body === custom_body
    @test normalized_custom.content_length == -1
    @test !normalized_custom.replayable
    @test_throws ArgumentError HT._normalize_body_input(_UnsupportedRequestBody())
end

@testset "queryparams decodes x-www-form-urlencoded bodies (#1118/#1123)" begin
    # queryparams decodes '+' (and %20) as space, so it round-trips the form
    # encoding produced by HTTP.post(url, [], dict).
    @test HT.queryparams(String(HT._form_urlencode(Dict("user" => "a b", "x" => "1")))) ==
          Dict("user" => "a b", "x" => "1")
    @test HT.queryparams("a=b+c&d=e%20f") == Dict("a" => "b c", "d" => "e f")
end
