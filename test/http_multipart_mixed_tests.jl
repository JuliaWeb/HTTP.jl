using Test
using HTTP

const HT = HTTP

@testset "multipart/mixed creation" begin
    # Test Form with :mixed type
    parts = [
        HT.Multipart(nothing, IOBuffer("part1"), "text/plain", "", ""),
        HT.Multipart(nothing, IOBuffer("part2"), "application/json", "", ""),
    ]
    form = HT.Form(parts)
    @test form.type == :mixed
    @test occursin("multipart/mixed", HT.content_type(form))

    # Test Batch convenience function with Vector{Multipart}
    batch = HT.Batch(parts)
    @test batch isa HT.Form
    @test batch.type == :mixed
    @test occursin("multipart/mixed", HT.content_type(batch))

    # Test Batch with Dict
    batch_dict = HT.Batch(Dict("key1" => "value1", "key2" => "value2"))
    @test batch_dict isa HT.Form
    @test batch_dict.type == :mixed
    @test occursin("multipart/mixed", HT.content_type(batch_dict))

    # Test Form constructor with type parameter
    form_mixed = HT.Form(Dict("key" => "value"); type=:mixed)
    @test form_mixed.type == :mixed
    ct = HT.content_type(form_mixed)
    @test startswith(ct, "multipart/mixed; boundary=")

    # Test that :formdata is the default
    form_default = HT.Form(Dict("key" => "value"))
    @test form_default.type == :formdata
    @test startswith(HT.content_type(form_default), "multipart/form-data; boundary=")

    # Test invalid type throws error
    @test_throws AssertionError HT.Form(Dict(); type=:invalid)
end

@testset "multipart/mixed parsing" begin
    # Create a multipart/mixed payload similar to SharePoint batch responses
    boundary = "batch_e3b6819b-13c3-43bb-85b2-24b14122fed1"
    body_text = join([
        "--$boundary",
        "Content-Type: application/http",
        "Content-Transfer-Encoding: binary",
        "",
        "HTTP/1.1 200 OK",
        "Content-Type: application/json",
        "",
        "{\"value\": \"response1\"}",
        "--$boundary",
        "Content-Type: application/http",
        "Content-Transfer-Encoding: binary",
        "",
        "HTTP/1.1 200 OK",
        "Content-Type: application/json",
        "",
        "{\"value\": \"response2\"}",
        "--$boundary--",
        "",
    ], "\r\n")

    body = Vector{UInt8}(body_text)
    ct = "multipart/mixed; boundary=$boundary"

    # Test parse_multipart_mixed
    parts = HT.parse_multipart_mixed(ct, body)
    @test parts !== nothing
    @test length(parts) == 2
    @test parts[1].contenttype == "application/http"
    @test parts[2].contenttype == "application/http"

    # Test that mixed parts don't require Content-Disposition
    @test parts[1].name == ""
    @test parts[2].name == ""

    # Test generic parse_multipart with type filter
    parts_filtered = HT.parse_multipart(ct, body, :mixed)
    @test parts_filtered !== nothing
    @test length(parts_filtered) == 2

    # Test that parse_multipart_form returns nothing for mixed content
    @test HT.parse_multipart_form(ct, body) === nothing

    # Test that parse_multipart_mixed returns nothing for form-data
    form_ct = "multipart/form-data; boundary=$boundary"
    @test HT.parse_multipart_mixed(form_ct, body) === nothing
end

@testset "parse_multipart generic parsing" begin
    boundary = "test_boundary_123"

    # Create a simple multipart/mixed body
    body_text = join([
        "--$boundary",
        "Content-Type: text/plain",
        "",
        "Hello World",
        "--$boundary",
        "Content-Type: application/json",
        "",
        "{\"key\":\"value\"}",
        "--$boundary--",
        "",
    ], "\r\n")

    body = Vector{UInt8}(body_text)
    ct = "multipart/mixed; boundary=$boundary"

    # Test generic parse_multipart without type filter
    parts = HT.parse_multipart(ct, body)
    @test parts !== nothing
    @test length(parts) == 2
    @test String(read(parts[1])) == "Hello World"
    @test String(read(parts[2])) == "{\"key\":\"value\"}"

    # Test with nil values
    @test HT.parse_multipart(nothing, body) === nothing
    @test HT.parse_multipart(ct, nothing) === nothing
    @test HT.parse_multipart(nothing, nothing) === nothing

    # Test with non-multipart content type
    @test HT.parse_multipart("text/plain", body) === nothing
end

@testset "parse_multipart_mixed with Request" begin
    boundary = "boundary456"
    body_text = join([
        "--$boundary",
        "Content-Type: text/plain",
        "",
        "test data",
        "--$boundary--",
        "",
    ], "\r\n")

    body_bytes = Vector{UInt8}(body_text)
    ct = "multipart/mixed; boundary=$boundary"

    request = HT.Request(
        "POST",
        "/batch";
        headers=["Content-Type" => ct],
        body=body_bytes,
    )

    parts = HT.parse_multipart_mixed(request)
    @test parts !== nothing
    @test length(parts) == 1
    @test String(read(parts[1])) == "test data"

    # Test with wrong content type
    plain_request = HT.Request("POST", "/upload"; headers=["Content-Type" => "text/plain"], body="test")
    @test HT.parse_multipart_mixed(plain_request) === nothing

    # Test with form-data
    form = HT.Form(Dict("key" => "value"))
    form_bytes = read(form)
    form_request = HT.Request(
        "POST",
        "/upload";
        headers=["Content-Type" => HT.content_type(form)],
        body=form_bytes,
    )
    @test HT.parse_multipart_mixed(form_request) === nothing
end

@testset "multipart/mixed round-trip" begin
    # Create multipart objects
    part1 = HT.Multipart(nothing, IOBuffer("First part content"), "text/plain", "", "")
    part2 = HT.Multipart(nothing, IOBuffer("{\"id\": 123}"), "application/json", "", "")

    # Create form and serialize
    form = HT.Form([part1, part2])
    @test form.type == :mixed
    body_bytes = read(form)
    ct = HT.content_type(form)

    # Parse back
    parsed_parts = HT.parse_multipart_mixed(ct, body_bytes)
    @test parsed_parts !== nothing
    @test length(parsed_parts) == 2
    @test String(read(parsed_parts[1])) == "First part content"
    @test String(read(parsed_parts[2])) == "{\"id\": 123}"
end

@testset "writemultipartheader Multipart filename branch (:formdata)" begin
    # Covers the `else` branch: filename !== nothing in :formdata mode
    part_with_file = HT.Multipart("report.csv", IOBuffer("a,b,c"), "text/csv", "", "upload")
    form = HT.Form(Pair["upload" => part_with_file]; type=:formdata)
    body_bytes = read(form)
    body_text = String(copy(body_bytes))
    @test occursin("filename=\"report.csv\"", body_text)
    @test occursin("Content-Type: text/csv", body_text)

    # Parse back via parse_multipart with required_type=:formdata
    ct = HT.content_type(form)
    parts = HT.parse_multipart(ct, body_bytes, :formdata)
    @test parts !== nothing
    @test length(parts) == 1
    @test parts[1].filename == "report.csv"
    @test String(read(parts[1])) == "a,b,c"
end

@testset "writemultipartheader Multipart contenttransferencoding branch" begin
    # Covers `contenttransferencoding != ""` → writes Content-Transfer-Encoding header
    part_cte = HT.Multipart(nothing, IOBuffer("binary data"), "application/octet-stream", "binary", "")
    form = HT.Form([part_cte])  # type=:mixed
    body_bytes = read(form)
    body_text = String(copy(body_bytes))
    @test occursin("Content-Transfer-Encoding: binary", body_text)

    # Round-trip: parse back
    ct = HT.content_type(form)
    parts = HT.parse_multipart_mixed(ct, body_bytes)
    @test parts !== nothing
    @test length(parts) == 1
    @test String(read(parts[1])) == "binary data"
end

@testset "writemultipartheader Multipart sniff contenttype branch" begin
    # Covers `contenttype == ""` → calls sniff(part.data)
    part_no_ct = HT.Multipart(nothing, IOBuffer("plain text"), "", "", "")
    form = HT.Form([part_no_ct])  # type=:mixed
    body_bytes = read(form)
    body_text = String(copy(body_bytes))
    # sniff should detect "text/plain; charset=utf-8"
    @test occursin("Content-Type: text/plain", body_text)
end

@testset "Form(d; type=:mixed) with IO value" begin
    # Covers the `isa(v, IO)` branch inside Form(d; ...) when type=:mixed
    io_val = IOBuffer("io content")
    form = HT.Form(Pair["1" => io_val]; type=:mixed)
    @test form.type == :mixed
    body_bytes = read(form)
    @test occursin("io content", String(copy(body_bytes)))
end

@testset "parse_multipart boundary length error" begin
    # Covers the `length(boundary_delimiter) > 70` error path
    long_boundary = 'a'^71
    ct = "multipart/mixed; boundary=$long_boundary"
    body = Vector{UInt8}("--$(long_boundary)\r\n\r\ndata\r\n--$(long_boundary)--\r\n")
    @test_throws ErrorException HT.parse_multipart(ct, body)
    @test_throws ErrorException HT.parse_multipart_mixed(ct, body)
end

@testset "parse_multipart with required_type=:formdata" begin
    # Covers the formdata require_contentdisposition=true path via parse_multipart
    boundary = "formboundary99"
    body_text = join([
        "--$boundary",
        "Content-Disposition: form-data; name=\"field1\"",
        "Content-Type: text/plain",
        "",
        "hello",
        "--$boundary--",
        "",
    ], "\r\n")
    body = Vector{UInt8}(body_text)
    ct = "multipart/form-data; boundary=$boundary"

    parts = HT.parse_multipart(ct, body, :formdata)
    @test parts !== nothing
    @test length(parts) == 1
    @test parts[1].name == "field1"
    @test String(read(parts[1])) == "hello"

    # required_type mismatch → nothing
    @test HT.parse_multipart(ct, body, :mixed) === nothing
end

@testset "parse_multipart(request) overload" begin
    boundary = "reqboundary7"
    body_text = join([
        "--$boundary",
        "Content-Type: text/plain",
        "",
        "batch body",
        "--$boundary--",
        "",
    ], "\r\n")
    body_bytes = Vector{UInt8}(body_text)
    ct = "multipart/mixed; boundary=$boundary"

    request = HT.Request("POST", "/batch"; headers=["Content-Type" => ct], body=body_bytes)
    parts = HT.parse_multipart(request)
    @test parts !== nothing
    @test length(parts) == 1
    @test String(read(parts[1])) == "batch body"

    # required_type filter via request overload
    parts_typed = HT.parse_multipart(request, :mixed)
    @test parts_typed !== nothing
    @test length(parts_typed) == 1

    # wrong required_type
    @test HT.parse_multipart(request, :formdata) === nothing

    # no Content-Type header
    bare_request = HT.Request("GET", "/")
    @test HT.parse_multipart(bare_request) === nothing
end
