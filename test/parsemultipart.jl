using Test
using HTTP
import HTTP.MultiPartParsing: find_multipart_boundary, find_multipart_boundaries, find_header_boundary, parse_multipart_chunk, parse_multipart_body, parse_multipart_form

function generate_test_body()
    Vector{UInt8}("""----------------------------918073721150061572809433\r
    Content-Disposition: form-data; name="namevalue"; filename="multipart.txt"\r
    Content-Type: text/plain\r
    \r
    not much to say\n\r
    ----------------------------918073721150061572809433\r
    Content-Disposition: form-data; name="key1"\r
    \r
    1\r
    ----------------------------918073721150061572809433\r
    Content-Disposition: form-data; name="key2"\r
    \r
    key the second\r
    ----------------------------918073721150061572809433\r
    Content-Disposition: form-data; name="namevalue2"; filename="multipart-leading-newline.txt"\r
    Content-Type: text/plain\r
    \r
    \nfile with leading newline\n\r
    ----------------------------918073721150061572809433--\r
    """)
end

function generate_test_request()
    headers = [
        "User-Agent" => "PostmanRuntime/7.15.2",
        "Accept" => "*/*",
        "Cache-Control" => "no-cache",
        "Postman-Token" => "288c2481-1837-4ba9-add3-f23d380fa440",
        "Host" => "localhost:8888",
        "Accept-Encoding" => "gzip, deflate",
        "Accept-Encoding" => "gzip, deflate",
        "Content-Type" => "multipart/form-data; boundary=--------------------------918073721150061572809433",
        "Content-Length" => "657",
        "Connection" => "keep-alive",
    ]

    HTTP.Request("POST", "/", headers, generate_test_body())
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
        "Content-Length" => "657",
        "Connection" => "keep-alive",
    ]

    HTTP.Request("POST", "/", headers, Vector{UInt8}())
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
        @test isTerminatingDelimiter
        @test 600 == startIndex
        # +2 because of the two additional '--' characters
        @test (startIndex + endIndexOffset + 2) == endIndex
    end


    @testset "parse_multipart_form" begin
        @test HTTP.parse_multipart_form(generate_non_multi_test_request()) === nothing

        multiparts = HTTP.parse_multipart_form(generate_test_request())
        @test 4 == length(multiparts)

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
    end
end
