using Test
using HTTP


function generateTestBody()
    IOBuffer("----------------------------276518006714602527406457\r\nContent-Disposition: form-data; name=\"namevalue\"; filename=\"multipart.txt\"\r\nContent-Type: text/plain\r\n\r\nnot much to say\n\r\n----------------------------276518006714602527406457\r\nContent-Disposition: form-data; name=\"key1\"\r\n\r\n1\r\n----------------------------276518006714602527406457\r\nContent-Disposition: form-data; name=\"key2\"\r\n\r\nkey the second\r\n----------------------------276518006714602527406457--\r\n")
end

function generateTestRequest()
    headers = [
        "User-Agent" => "PostmanRuntime/7.15.2",
        "Accept" => "*/*",
        "Cache-Control" => "no-cache",
        "Postman-Token" => "288c2481-1837-4ba9-add3-f23d380fa440",
        "Host" => "localhost:8888",
        "Accept-Encoding" => "gzip, deflate",
        "Content-Type" => "multipart/form-data; boundary=--------------------------276518006714602527406457",
        "Content-Length" => "457",
        "Connection" => "keep-alive",
    ]

    HTTP.Request("POST", "/", headers, generateTestBody().data)
end


@testset "parse_multipart_form" begin
    multiparts = HTTP.parse_multipart_form(generateTestRequest())
    @test 3 == length(multiparts)
    @test "multipart.txt" === multiparts[1].filename
    @test "not much to say\n" === String(read(multiparts[1].data))
    @test "text/plain" === multiparts[1].contenttype
    @test "namevalue" === multiparts[1].name
end
