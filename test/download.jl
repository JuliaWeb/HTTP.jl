using HTTP

@testset "HTTP.download" begin
    @testset "Content-Disposition" begin
        invalid_content_disposition_fn = HTTP.download(
            "http://test.greenbytes.de/tech/tc2231/attonlyquoted.asis")
        @test isfile(invalid_content_disposition_fn)
        @test basename(invalid_content_disposition_fn) == "attonlyquoted.asis" # just last part  of name



        content_disposition_fn = HTTP.download(
            "http://test.greenbytes.de/tech/tc2231/inlwithasciifilenamepdf.asis")
        @test isfile(content_disposition_fn)
        @test basename(content_disposition_fn) == "foo.pdf"

        escaped_content_disposition_fn = HTTP.download(
            "http://test.greenbytes.de/tech/tc2231/attwithasciifnescapedquote.asis")
        @test isfile(escaped_content_disposition_fn)
        @test basename(escaped_content_disposition_fn) == "\"quoting\" tested.html"
    end

    @testset "Provided Filename" begin
        provided_filename = tempname()
        returned_filename = HTTP.download(
            "http://test.greenbytes.de/tech/tc2231/inlwithasciifilenamepdf.asis",
            provided_filename
        )
        @test provided_filename == returned_filename
        @test isfile(provided_filename)


    end

    @testset "Content-Encoding" begin
        gzip_content_encoding_fn = HTTP.download("https://httpbin.org/gzip")
        @test isfile(gzip_content_encoding_fn)
        @test last(splitext(gzip_content_encoding_fn)) == ".gz"
    end
end
