using Dates
using Test
using HTTP
using HTTP: Headers, URI
using HTTP.AWS4AuthRequest: sign_aws4!

# Based on https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html
# and https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html

function test_sign!(method, headers, params, body=""; opts...)
    sign_aws4!(method,
               URI("https://example.amazonaws.com/" * params),
               headers,
               Vector{UInt8}(body);
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

function test_auth_string(headers, sig, key="AKIDEXAMPLE", date="20150830", service="service")
    d = [
        "AWS4-HMAC-SHA256 Credential" => "$key/$date/us-east-1/$service/aws4_request",
        "SignedHeaders" => headers,
        "Signature" => sig,
    ]
    join(map(p->join(p, '='), d), ", ")
end

header_keys(headers) = sort!(map(first, headers))

const required_headers = ["Authorization", "host", "x-amz-date"]

@testset "AWS Signature Version 4" begin
    # The signature for requests with no headers where the path ends up as simply /
    slash_only_sig = "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
    noheaders = [
        ("get-vanilla", "", slash_only_sig),
        ("get-vanilla-empty-query-key", "?Param1=value1", "a67d582fa61cc504c4bae71f336f98b97f1ea3c7a6bfe1b6e45aec72011b9aeb"),
        ("get-utf8", "ሴ", "8318018e0b0f223aa2bbf98705b62bb787dc9c0e678f255a891fd03141be5d85"),
        ("get-relative", "example/..", slash_only_sig),
        ("get-relative-relative", "example1/example2/../..", slash_only_sig),
        ("get-slash", "/", slash_only_sig),
        ("get-slash-dot-slash", "./", slash_only_sig),
        ("get-slashes", "example/", "9a624bd73a37c9a373b5312afbebe7a714a789de108f0bdfe846570885f57e84"),
        ("get-slash-pointless-dot", "./example", "ef75d96142cf21edca26f06005da7988e4f8dc83a165a80865db7089db637ec5"),
        ("get-space", "example space/", "652487583200325589f1fba4c7e578f72c47cb61beeca81406b39ddec1366741"),
        ("post-vanilla", "", "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"),
        ("post-vanilla-empty-query-value", "?Param1=value1", "28038455d6de14eafc1f9222cf5aa6f1a96197d7deb8263271d420d138af7f11"),
    ]
    @testset "$name" for (name, p, sig) in noheaders
        m = startswith(name, "get") ? "GET" : "POST"
        headers = test_sign!(m, Headers([]), p)
        @test header_keys(headers) == required_headers
        d = Dict(headers)
        @test d["x-amz-date"] == "20150830T123600Z"
        @test d["host"] == "example.amazonaws.com"
        @test d["Authorization"] == test_auth_string("host;x-amz-date", sig)
    end

    yesheaders = [
        ("get-header-key-duplicate", "", "",
         Headers(["My-Header1" => "value2",
                  "My-Header1" => "value2",
                  "My-Header1" => "value1"]),
         "host;my-header1;x-amz-date",
         "c9d5ea9f3f72853aea855b47ea873832890dbdd183b4468f858259531a5138ea"),
        ("get-header-value-multiline", "", "",
         Headers(["My-Header1" => "value1\n  value2\n    value3"]),
         "host;my-header1;x-amz-date",
         "ba17b383a53190154eb5fa66a1b836cc297cc0a3d70a5d00705980573d8ff790"),
        ("get-header-value-order", "", "",
         Headers(["My-Header1" => "value4",
                  "My-Header1" => "value1",
                  "My-Header1" => "value3",
                  "My-Header1" => "value2"]),
         "host;my-header1;x-amz-date",
         "08c7e5a9acfcfeb3ab6b2185e75ce8b1deb5e634ec47601a50643f830c755c01"),
        ("get-header-value-trim", "", "",
         Headers(["My-Header1" => " value1",
                  "My-Header2" => " \"a   b   c\""]),
         "host;my-header1;my-header2;x-amz-date",
         "acc3ed3afb60bb290fc8d2dd0098b9911fcaa05412b367055dee359757a9c736"),
        ("post-header-key-sort", "", "",
         Headers(["My-Header1" => "value1"]),
         "host;my-header1;x-amz-date",
         "c5410059b04c1ee005303aed430f6e6645f61f4dc9e1461ec8f8916fdf18852c"),
        ("post-header-value-case", "", "",
         Headers(["My-Header1" => "VALUE1"]),
         "host;my-header1;x-amz-date",
         "cdbc9802e29d2942e5e10b5bccfdd67c5f22c7c4e8ae67b53629efa58b974b7d"),
        ("post-x-www-form-urlencoded", "", "Param1=value1",
         Headers(["Content-Type" => "application/x-www-form-urlencoded",
                  "Content-Length" => "13"]),
         "content-type;host;x-amz-date",
         "ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a"),
        ("post-x-www-form-urlencoded-parameters", "", "Param1=value1",
         Headers(["Content-Type" => "application/x-www-form-urlencoded; charset=utf8",
                  "Content-Length" => "13"]),
         "content-type;host;x-amz-date",
         "1a72ec8f64bd914b0e42e42607c7fbce7fb2c7465f63e3092b3b0d39fa77a6fe"),
    ]
    @testset "$name" for (name, p, body, h, sh, sig) in yesheaders
        hh = sort(map(first, h))
        m = startswith(name, "get") ? "GET" : "POST"
        test_sign!(m, h, p, body)
        @test header_keys(h) == sort(vcat(required_headers, hh))
        d = Dict(h) # collapses duplicates but we don't care here
        @test d["x-amz-date"] == "20150830T123600Z"
        @test d["host"] == "example.amazonaws.com"
        @test d["Authorization"] == test_auth_string(sh, sig)
    end

    @testset "AWS Security Token Service" begin
        # Not a real security token, provided by AWS as an example
        token = string("AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwd",
                       "QWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI/qkPpKPi/k",
                       "McGdQrmGdeehM4IC1NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXD",
                       "vp75YU9HFvlRd8Tx6q6fE8YQcHNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64",
                       "lIZbqBAz+scqKmlzm8FDrypNC9Yjc8fPOLn9FX9KSYvKTr4rvx3iSIlTJabIQwj2I",
                       "CCR/oLxBA==")
        @testset "Token included in signature" begin
            sh = "host;x-amz-date;x-amz-security-token"
            sig = "85d96828115b5dc0cfc3bd16ad9e210dd772bbebba041836c64533a82be05ead"
            h = test_sign!("POST", Headers([]), "", aws_session_token=token)
            d = Dict(h)
            @test d["Authorization"] == test_auth_string(sh, sig)
            @test haskey(d, "x-amz-security-token")
        end
        @testset "Token not included in signature" begin
            sh = "host;x-amz-date"
            sig = "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"
            h = test_sign!("POST", Headers([]), "", aws_session_token=token, token_in_signature=false)
            d = Dict(h)
            @test d["Authorization"] == test_auth_string(sh, sig)
            @test haskey(d, "x-amz-security-token")
        end
    end

    @testset "AWS Simple Storage Service" begin
        s3url = "https://examplebucket.s3.amazonaws.com"
        opts = (timestamp=DateTime(2013, 5, 24),
                aws_service="s3",
                aws_region="us-east-1",
                # NOTE: These are the example credentials as specified in the AWS docs,
                # they are not real
                aws_access_key_id="AKIAIOSFODNN7EXAMPLE",
                aws_secret_access_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                include_md5=false)

        @testset "GET Object" begin
            sh = "host;range;x-amz-content-sha256;x-amz-date"
            sig = "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
            h = Headers(["Range" => "bytes=0-9"])
            sign_aws4!("GET", URI(s3url * "/test.txt"), h, UInt8[]; opts...)
            d = Dict(h)
            @test d["Authorization"] == test_auth_string(sh, sig, opts.aws_access_key_id, "20130524", "s3")
            @test haskey(d, "x-amz-content-sha256") # required for S3 requests
        end

        @testset "PUT Object" begin
            sh = "date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class"
            sig = "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
            h = Headers(["Date" => "Fri, 24 May 2013 00:00:00 GMT",
                         "x-amz-storage-class" => "REDUCED_REDUNDANCY"])
            sign_aws4!("PUT", URI(s3url * "/test\$file.text"), h, UInt8[];
                       # Override the SHA-256 of the request body, since the actual body is not provided
                       # for this example in the documentation, only the SHA
                       body_sha256=hex2bytes("44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"),
                       opts...)
            d = Dict(h)
            @test d["Authorization"] == test_auth_string(sh, sig, opts.aws_access_key_id, "20130524", "s3")
            @test haskey(d, "x-amz-content-sha256")
        end

        @testset "GET Bucket Lifecycle" begin
            sh = "host;x-amz-content-sha256;x-amz-date"
            sig = "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"
            h = Headers([])
            sign_aws4!("GET", URI(s3url * "/?lifecycle"), h, UInt8[]; opts...)
            d = Dict(h)
            @test d["Authorization"] == test_auth_string(sh, sig, opts.aws_access_key_id, "20130524", "s3")
            @test haskey(d, "x-amz-content-sha256")
        end

        @testset "GET Bucket (List Objects)" begin
            sh = "host;x-amz-content-sha256;x-amz-date"
            sig = "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"
            h = Headers([])
            sign_aws4!("GET", URI(s3url * "/?max-keys=2&prefix=J"), h, UInt8[]; opts...)
            d = Dict(h)
            @test d["Authorization"] == test_auth_string(sh, sig, opts.aws_access_key_id, "20130524", "s3")
            @test haskey(d, "x-amz-content-sha256")
        end
    end
end

