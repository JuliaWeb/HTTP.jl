using Dates
using Test
using HTTP
using HTTP: Headers, URI
using HTTP.AWS4AuthRequest: sign_aws4!

# Based on https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html

function test_get!(headers, params; opts...)
    sign_aws4!("GET",
               URI("https://example.amazonaws.com/" * params),
               headers,
               UInt8[];
               timestamp=DateTime(2015, 8, 30, 12, 36),
               aws_service="service",
               aws_region="us-east-1",
               # NOTE: These are the example credentials as specified in the AWS docs,
               # they are not real
               aws_access_key_id="AKIDEXAMPLE",
               aws_secret_access_key="wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
               include_md5=false,
               include_sha256=false,
               opts...)
    headers
end

function test_auth_string(headers, sig)
    d = [
        "AWS4-HMAC-SHA256 Credential" => "AKIDEXAMPLE/20150830/us-east-1/service/aws4_request",
        "SignedHeaders" => headers,
        "Signature" => sig,
    ]
    join(map(p->join(p, '='), d), ", ")
end

header_keys(headers) = sort!(map(first, headers))

const required_headers = ["Authorization", "host", "x-amz-date"]

@testset "AWS Signature Version 4" begin
    noheaders = [
        ("get-vanilla", "", "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"),
        ("get-vanilla-empty-query-key", "?Param1=value1", "a67d582fa61cc504c4bae71f336f98b97f1ea3c7a6bfe1b6e45aec72011b9aeb"),
        ("get-utf8", "ሴ", "8318018e0b0f223aa2bbf98705b62bb787dc9c0e678f255a891fd03141be5d85"),
    ]
    @testset "$name" for (name, p, sig) in noheaders
        headers = test_get!(Headers([]), p)
        @test header_keys(headers) == required_headers
        d = Dict(headers)
        @test d["x-amz-date"] == "20150830T123600Z"
        @test d["host"] == "example.amazonaws.com"
        @test d["Authorization"] == test_auth_string("host;x-amz-date", sig)
    end

    yesheaders = [
        ("get-header-key-duplicate", "",
         Headers(["My-Header1" => "value2",
                  "My-Header1" => "value2",
                  "My-Header1" => "value1"]),
         "host;my-header1;x-amz-date",
         "c9d5ea9f3f72853aea855b47ea873832890dbdd183b4468f858259531a5138ea"),
        ("get-header-value-multiline", "",
         Headers(["My-Header1" => "value1\n  value2\n    value3"]),
         "host;my-header1;x-amz-date",
         "ba17b383a53190154eb5fa66a1b836cc297cc0a3d70a5d00705980573d8ff790"),
        ("get-header-value-order", "",
         Headers(["My-Header1" => "value4",
                  "My-Header1" => "value1",
                  "My-Header1" => "value3",
                  "My-Header1" => "value2"]),
         "host;my-header1;x-amz-date",
         "08c7e5a9acfcfeb3ab6b2185e75ce8b1deb5e634ec47601a50643f830c755c01"),
        ("get-header-value-trim", "",
         Headers(["My-Header1" => " value1",
                  "My-Header2" => " \"a   b   c\""]),
         "host;my-header1;my-header2;x-amz-date",
         "acc3ed3afb60bb290fc8d2dd0098b9911fcaa05412b367055dee359757a9c736"),
    ]
    @testset "$name" for (name, p, h, sh, sig) in yesheaders
        hh = sort(map(first, h))
        test_get!(h, p)
        @test header_keys(h) == sort(vcat(required_headers, hh))
        d = Dict(h) # collapses duplicates but we don't care here
        @test d["x-amz-date"] == "20150830T123600Z"
        @test d["host"] == "example.amazonaws.com"
        @test d["Authorization"] == test_auth_string(sh, sig)
    end
end

