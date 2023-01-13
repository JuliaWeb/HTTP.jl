using HTTP

import ..httpbin

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
        # HTTP.jl#896
        file = HTTP.download("https://www.cryst.ehu.es/")
        @test isfile(file) # just ensure it downloads and doesn't stack overflow
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
        # Add gz extension if we are determining the filename
        gzip_content_encoding_fn = HTTP.download("https://$httpbin/gzip")
        @test isfile(gzip_content_encoding_fn)

        # Check content auto decoding
        open(gzip_content_encoding_fn, "r") do f
            @test HTTP.sniff(read(f, String)) == "application/json; charset=utf-8"
        end

        # But not if the local name is fully given. HTTP#573
        mktempdir() do dir
            name = joinpath(dir, "foo")
            downloaded_name = HTTP.download(
                "https://pkg.julialang.org/registry/23338594-aafe-5451-b93e-139f81909106/7858451b7a520344eb60354f69809d30a44e7dae",
                name,
            )
            @test name == downloaded_name
        end
    end
end
