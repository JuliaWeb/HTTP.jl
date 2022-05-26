using Test
using HTTP
import HTTP.MultiPartParsing: find_multipart_boundary, find_multipart_boundaries, find_header_boundary, parse_multipart_chunk, parse_multipart_body, parse_multipart_form

function generate_test_body()
    Vector{UInt8}(join([
        "----------------------------918073721150061572809433",
        "Content-Disposition: form-data; name=\"namevalue\"; filename=\"multipart.txt\"",
        "Content-Type: text/plain",
        "",
        "not much to say\n",
        "----------------------------918073721150061572809433",
        "Content-Disposition: form-data; name=\"key1\"",
        "",
        "1",
        "----------------------------918073721150061572809433",
        "Content-Disposition: form-data; name=\"key2\"",
        "",
        "key the second",
        "----------------------------918073721150061572809433",
        "Content-Disposition: form-data; name=\"namevalue2\"; filename=\"multipart-leading-newline.txt\"",
        "Content-Type: text/plain",
        "",
        "\nfile with leading newline\n",
        "----------------------------918073721150061572809433",
        "Content-Disposition: form-data; name=\"json_file1\"; filename=\"my-json-file-1.json\"",
        "Content-Type: application/json",
        "",
        "{\"data\": [\"this is json data\"]}",
        "----------------------------918073721150061572809433--",
        "",
    ], "\r\n"))
end

function generate_test_request()
    body = generate_test_body()
    
    headers = [
        "User-Agent" => "PostmanRuntime/7.15.2",
        "Accept" => "*/*",
        "Cache-Control" => "no-cache",
        "Postman-Token" => "288c2481-1837-4ba9-add3-f23d380fa440",
        "Host" => "localhost:8888",
        "Accept-Encoding" => "gzip, deflate",
        "Accept-Encoding" => "gzip, deflate",
        "Content-Type" => "multipart/form-data; boundary=--------------------------918073721150061572809433",
        "Content-Length" => string(length(body)),
        "Connection" => "keep-alive",
    ]

    HTTP.Request("POST", "/", headers, body)
end

function generate_non_multi_test_request()
    headers = [
        "User-Agent" => "PostmanRuntime/7.15.2",
        "Accept" => "*/*",
        "Cache-Control" => "no-cache",
        "Postman-Token" => "288c2481-1837-4ba9-add3-f23d380fa440",
        "Host" => "localhost:8888",
        "Accept-Encoding" => "gzip, deflate",
        "Accept-Encoding" => "gzip, deflate",
        "Content-Length" => "0",
        "Connection" => "keep-alive",
    ]

    HTTP.Request("POST", "/", headers, Vector{UInt8}())
end

function generate_test_response()
    body = generate_test_body()

    headers = [
        "Date" => "Fri, 25 Mar 2022 14:16:21 GMT",
        "Transfer-Encoding" => "chunked",
        "Content-Type" => "multipart/form-data; boundary=--------------------------918073721150061572809433",
        "Content-Length" => string(length(body)),
        "Connection" => "keep-alive",
    ]

    HTTP.Response(200, headers, body=body)
end


@testset "parse multipart form-data" begin
    @testset "find_multipart_boundary" begin
        request = generate_test_request()

        # NOTE: this is the start of a "boundary delimiter line" and has two leading
        # '-' characters prepended to the boundary delimiter from Content-Type header
        delimiter = Vector{UInt8}("--------------------------918073721150061572809433")
        body = generate_test_body()
        # length of the delimiter, CRLF, and -1 for the end index to be the LF character
        endIndexOffset = length(delimiter) + 4 - 1

        (isTerminatingDelimiter, startIndex, endIndex) = find_multipart_boundary(body, delimiter)
        @test !isTerminatingDelimiter
        @test 1 == startIndex
        @test (startIndex + endIndexOffset) == endIndex

        # the remaining "boundary delimiter lines" will have a CRLF preceding them
        endIndexOffset += 2

        (isTerminatingDelimiter, startIndex, endIndex) = find_multipart_boundary(body, delimiter, start = startIndex + 1)
        @test !isTerminatingDelimiter
        @test 175 == startIndex
        @test (startIndex + endIndexOffset) == endIndex

        (isTerminatingDelimiter, startIndex, endIndex) = find_multipart_boundary(body, delimiter, start = startIndex + 3)
        @test !isTerminatingDelimiter
        @test 279 == startIndex
        @test (startIndex + endIndexOffset) == endIndex

        (isTerminatingDelimiter, startIndex, endIndex) = find_multipart_boundary(body, delimiter, start = startIndex + 3)
        @test !isTerminatingDelimiter
        @test 396 == startIndex
        @test (startIndex + endIndexOffset) == endIndex

        (isTerminatingDelimiter, startIndex, endIndex) = find_multipart_boundary(body, delimiter, start = startIndex + 3)
        @test !isTerminatingDelimiter
        @test 600 == startIndex
        @test (startIndex + endIndexOffset) == endIndex

        (isTerminatingDelimiter, startIndex, endIndex) = find_multipart_boundary(body, delimiter, start = startIndex + 3)
        @test isTerminatingDelimiter
        @test 804 == startIndex
        # +2 because of the two additional '--' characters
        @test (startIndex + endIndexOffset + 2) == endIndex
    end


    @testset "parse_multipart_form request" begin
        @test HTTP.parse_multipart_form(generate_non_multi_test_request()) === nothing

        multiparts = HTTP.parse_multipart_form(generate_test_request())
        @test 5 == length(multiparts)

        @test "multipart.txt" === multiparts[1].filename
        @test "namevalue" === multiparts[1].name
        @test "text/plain" === multiparts[1].contenttype
        @test "not much to say\n" === String(read(multiparts[1].data))

        @test multiparts[2].filename === nothing
        @test "key1" === multiparts[2].name
        @test "text/plain" === multiparts[2].contenttype
        @test "1" === String(read(multiparts[2].data))

        @test multiparts[3].filename === nothing
        @test "key2" === multiparts[3].name
        @test "text/plain" === multiparts[3].contenttype
        @test "key the second" === String(read(multiparts[3].data))

        @test "multipart-leading-newline.txt" === multiparts[4].filename
        @test "namevalue2" === multiparts[4].name
        @test "text/plain" === multiparts[4].contenttype
        @test "\nfile with leading newline\n" === String(read(multiparts[4].data))

        @test "my-json-file-1.json" === multiparts[5].filename
        @test "json_file1" === multiparts[5].name
        @test "application/json" === multiparts[5].contenttype
        @test """{"data": ["this is json data"]}""" === String(read(multiparts[5].data))
    end

    @testset "parse_multipart_form response" begin
        multiparts = HTTP.parse_multipart_form(generate_test_response())
        @test 5 == length(multiparts)

        @test "multipart.txt" === multiparts[1].filename
        @test "namevalue" === multiparts[1].name
        @test "text/plain" === multiparts[1].contenttype
        @test "not much to say\n" === String(read(multiparts[1].data))

        @test multiparts[2].filename === nothing
        @test "key1" === multiparts[2].name
        @test "text/plain" === multiparts[2].contenttype
        @test "1" === String(read(multiparts[2].data))

        @test multiparts[3].filename === nothing
        @test "key2" === multiparts[3].name
        @test "text/plain" === multiparts[3].contenttype
        @test "key the second" === String(read(multiparts[3].data))

        @test "multipart-leading-newline.txt" === multiparts[4].filename
        @test "namevalue2" === multiparts[4].name
        @test "text/plain" === multiparts[4].contenttype
        @test "\nfile with leading newline\n" === String(read(multiparts[4].data))

        @test "my-json-file-1.json" === multiparts[5].filename
        @test "json_file1" === multiparts[5].name
        @test "application/json" === multiparts[5].contenttype
        @test """{"data": ["this is json data"]}""" === String(read(multiparts[5].data))
    end
end
