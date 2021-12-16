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

    @testset "filename from remote path" begin

        file = HTTP.download("https://httpbingo.julialang.org/html")
        @test basename(file) == "html"
        file = HTTP.download("https://httpbingo.julialang.org/redirect/2")
        @test basename(file) == "2"
        # HTTP.jl#696
        file = HTTP.download("https://httpbingo.julialang.org/html?a=b")
        @test basename(file) == "html"
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

        # HTTP#760
        # This has a redirect, where the original Response has the Content-Disposition
        # but the redirected one doesn't
        # Neither https://httpbingo.julialang.org/ nor http://test.greenbytes.de/tech/tc2231/
        # has a test-case for this. See: https://github.com/postmanlabs/httpbin/issues/652
        # This test might stop validating the code-path if FigShare changes how they do
        # redirects (which they have done before, causing issue HTTP#760, in the first place)
        redirected_content_disposition_fn = HTTP.download(
            "https://ndownloader.figshare.com/files/6294558")
        @test isfile(redirected_content_disposition_fn)
        @test basename(redirected_content_disposition_fn) == "rsta20150293_si_001.xlsx"
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
