using Dates
using Test
using HTTP
using HTTP: Headers, URI
using HTTP.AWS4AuthRequest: sign_aws4!

# Based on https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html

@testset "AWS Signature Version 4" begin
    # NOTE: These are the example credentials as specified in the AWS docs, they are not real
    withenv("AWS_ACCESS_KEY_ID" => "AKIDEXAMPLE",
            "AWS_SECRET_ACCESS_KEY" => "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY") do

        cases = [
            ("get-vanilla", "", "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"),
            ("get-vanilla-empty-query-key", "?Param1=value1", "a67d582fa61cc504c4bae71f336f98b97f1ea3c7a6bfe1b6e45aec72011b9aeb"),
            ("get-utf8", "ሴ", "8318018e0b0f223aa2bbf98705b62bb787dc9c0e678f255a891fd03141be5d85"),
        ]
        for (name, p, sig) in cases
            @testset "$name" begin
                headers = Headers([])
                sign_aws4!("GET",
                           URI("https://example.amazonaws.com/" * p),
                           headers,
                           UInt8[];
                           timestamp=DateTime(2015, 8, 30, 12, 36),
                           aws_service="service",
                           aws_region="us-east-1",
                           include_md5=false,
                           include_sha256=false)
                @test sort(map(first, headers)) == ["Authorization", "host", "x-amz-date"]
                d = Dict(headers)
                @test d["x-amz-date"] == "20150830T123600Z"
                @test d["host"] == "example.amazonaws.com"
                auth = string("AWS4-HMAC-SHA256 ",
                              "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, ",
                              "SignedHeaders=host;x-amz-date, ",
                              "Signature=", sig)
                @test d["Authorization"] == auth
            end
        end
    end
end

