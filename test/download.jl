using HTTP

@testset "HTTP.download" begin
    @testset "Update Period" begin
        @test_logs (:info, "Downloading") HTTP.download(
        "http://test.greenbytes.de/tech/tc2231/inlwithasciifilenamepdf.asis";)
        @test_logs (:info, "Downloading") HTTP.download(
        "http://test.greenbytes.de/tech/tc2231/inlwithasciifilenamepdf.asis";
        update_period=0.5)
        @test_logs HTTP.download(
        "http://test.greenbytes.de/tech/tc2231/inlwithasciifilenamepdf.asis";
        update_period=Inf)
    end

    @testset "Content-Disposition" begin
        invalid_content_disposition_fn = HTTP.download(
            "http://test.greenbytes.de/tech/tc2231/attonlyquoted.asis")
        @test isfile(invalid_content_disposition_fn)
        @test basename(invalid_content_disposition_fn) == "attonlyquoted.asis"

        content_disposition_fn = HTTP.download(
            "http://test.greenbytes.de/tech/tc2231/inlwithasciifilenamepdf.asis")
        @test isfile(content_disposition_fn)
        @test basename(content_disposition_fn) == "foo.pdf"

        if Sys.isunix() # Don't try this on windows, quotes are not allowed in windows filenames.
            escaped_content_disposition_fn = HTTP.download(
                "http://test.greenbytes.de/tech/tc2231/attwithasciifnescapedquote.asis")
            @test isfile(escaped_content_disposition_fn)
            @test basename(escaped_content_disposition_fn) == "\"quoting\" tested.html"
        end
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
