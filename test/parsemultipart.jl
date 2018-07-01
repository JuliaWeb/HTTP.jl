using Test
using HTTP


function generate_test_body()
    IOBuffer("----------------------------918073721150061572809433\r\nContent-Disposition: form-data; name=\"namevalue\"; filename=\"multipart.txt\"\r\nContent-Type: text/plain\r\n\r\nnot much to say\n\r\n----------------------------918073721150061572809433\r\nContent-Disposition: form-data; name=\"key1\"\r\n\r\n1\r\n----------------------------918073721150061572809433\r\nContent-Disposition: form-data; name=\"key2\"\r\n\r\nkey the second\r\n----------------------------918073721150061572809433\r\nContent-Disposition: form-data; name=\"namevalue2\"; filename=\"multipart-leading-newline.txt\"\r\nContent-Type: text/plain\r\n\r\n\nfile with leading newline\n\r\n----------------------------918073721150061572809433--\r\n").data
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


@testset "parse multipart form-data" begin
    @testset "find_multipart_boundary" begin
        request = generate_test_request()

        # NOTE: this is the start of a "boundary delimiter line" and has two leading
        # '-' characters prepended to the boundary delimiter from Content-Type header
        delimiter = IOBuffer("----------------------------918073721150061572809433").data
        body = generate_test_body()
        # length of the delimiter, CRLF, and -1 for the end index to be the LF character
        endIndexOffset = length(delimiter) + 2 - 1

        (isTerminatingDelimiter, startIndex, endIndex) = HTTP.find_multipart_boundary(body, delimiter)
        @test !isTerminatingDelimiter
        @test 1 == startIndex
        @test (startIndex + endIndexOffset) == endIndex

        # the remaining "boundary delimiter lines" will have a CRLF preceding them
        endIndexOffset += 2

        (isTerminatingDelimiter, startIndex, endIndex) = HTTP.find_multipart_boundary(body, delimiter, start = startIndex + 1)
        @test !isTerminatingDelimiter
        @test 175 == startIndex
        @test (startIndex + endIndexOffset) == endIndex

        (isTerminatingDelimiter, startIndex, endIndex) = HTTP.find_multipart_boundary(body, delimiter, start = startIndex + 3)
        @test !isTerminatingDelimiter
        @test 279 == startIndex
        @test (startIndex + endIndexOffset) == endIndex

        (isTerminatingDelimiter, startIndex, endIndex) = HTTP.find_multipart_boundary(body, delimiter, start = startIndex + 3)
        @test !isTerminatingDelimiter
        @test 396 == startIndex
        @test (startIndex + endIndexOffset) == endIndex

        (isTerminatingDelimiter, startIndex, endIndex) = HTTP.find_multipart_boundary(body, delimiter, start = startIndex + 3)
        @test isTerminatingDelimiter
        @test 600 == startIndex
        # +2 because of the two additional '--' characters
        @test (startIndex + endIndexOffset + 2) == endIndex
    end


    @testset "parse_multipart_form" begin
        multiparts = HTTP.parse_multipart_form(generate_test_request())
        @test 4 == length(multiparts)

        @test "multipart.txt" === multiparts[1].filename
        @test "namevalue" === multiparts[1].name
        @test "text/plain" === multiparts[1].contenttype
        @test "not much to say\n" === String(read(multiparts[1].data))

        @test isnothing(multiparts[2].filename)
        @test "key1" === multiparts[2].name
        @test "text/plain" === multiparts[2].contenttype
        @test "1" === String(read(multiparts[2].data))

        @test isnothing(multiparts[3].filename)
        @test "key2" === multiparts[3].name
        @test "text/plain" === multiparts[3].contenttype
        @test "key the second" === String(read(multiparts[3].data))

        @test "multipart-leading-newline.txt" === multiparts[4].filename
        @test "namevalue2" === multiparts[4].name
        @test "text/plain" === multiparts[4].contenttype
        @test "\nfile with leading newline\n" === String(read(multiparts[4].data))
    end
end

@testset "content_disposition_extract($(v[1])" for v in (
        ("; filename=abc.txt ; name = xyz", "xyz", "abc.txt"),
        ("; name=abc ; filename = xyz", "abc", "xyz"),
        ("""; mno;filename="abc";name=xyz""", "xyz", "abc"),
        (""";filename="abc";mno;name=xyz""", "xyz", "abc"),
        (""";filename=   "abc"   ;mno;name=xyz""", "xyz", "abc"),
        ("; filename=abc.txt ; name = xyz ;", "xyz", "abc.txt"),
        ("; filename=abc.txt ; name = xyz;", "xyz", "abc.txt"),
        ("; filename=abc.txt ; name = xyz ; mno", "xyz", "abc.txt"),
        ("; filename=abc.txt ; name = xyz ; mno ;", "xyz", "abc.txt"),
        (";name=\"ab\\\"cdef\"","ab\\\"cdef", nothing),
        (";filename=abc\\;xyz", nothing, "abc\\;xyz"),
        (";filename=\\\"abc;name=xyz", "xyz", "\\\"abc"),
        (";name=xyz;filename=;mno", "xyz", nothing),
        (";name=\"xy;z\";filename=;mno", "xy;z", nothing),
        (";name=\"x=z\";filename=bbb", "x=z", "bbb")
        )
    name = nothing
    filename = nothing

    for (pair, key, value) in HTTP.content_disposition_extract(v[1])
        if pair && key == "name"
            name = value
        elseif pair && key == "filename"
            filename = value
        end
    end

    @test name == v[2]
    @test filename == v[3]
end
