module TestParser

using Test, HTTP, HTTP.Messages, HTTP.Parsers, HTTP.Strings
include(joinpath(dirname(pathof(HTTP)), "../test/resources/HTTPMessages.jl"))
using .HTTPMessages

import Base.==

const strict = false

==(a::Request,b::Request) = (a.method         == b.method)    &&
                           (a.version        == b.version)   &&
                           (a.headers        == b.headers)   &&
                           (a.body           == b.body)

@testset "HTTP.parser" begin
    @testset "Parser Error Recovery" begin
        @testset "Malformed messages" begin
            # Test malformed request with missing HTTP version
            reqstr = "GET /\r\n"
            @test_throws HTTP.ParseError HTTP.Parsers.parse_request_line!(reqstr, HTTP.Request())

            # Test malformed request with invalid HTTP version
            reqstr = "GET / XHTTP/1.1\r\n"
            @test_throws HTTP.ParseError HTTP.Parsers.parse_request_line!(reqstr, HTTP.Request())

            # Test malformed request with invalid header format
            reqstr = "Invalid-Header\r\n"
            @test_throws HTTP.ParseError HTTP.Parsers.parse_header_field(SubString(reqstr))

            # Test malformed request with missing header value
            reqstr = "Content-Type\r\n"
            @test_throws HTTP.ParseError HTTP.Parsers.parse_header_field(SubString(reqstr))
        end

        @testset "Partial reads" begin
            # Test complete request line parsing
            reqstr = "POST / HTTP/1.1\r\n"
            req = HTTP.Request()
            rest = HTTP.Parsers.parse_request_line!(reqstr, req)
            @test req.method == "POST"
            @test req.target == "/"
            @test req.version == v"1.1"

            # Test complete header parsing
            reqstr = "Content-Length: 10\r\nHost: test\r\n\r\n"
            headers = Pair{SubString{String},SubString{String}}[]
            rest = SubString(reqstr)
            while !isempty(rest)
                header, rest = HTTP.Parsers.parse_header_field(rest)
                if header != HTTP.Parsers.emptyheader
                    push!(headers, header)
                end
            end
            @test length(headers) == 2
            @test any(h -> h.first == "Content-Length" && h.second == "10", headers)
            @test any(h -> h.first == "Host" && h.second == "test", headers)
        end

        @testset "Interrupted connections" begin
            # Test connection interruption by attempting to connect to a non-existent host
            @test_throws Union{HTTP.ConnectError,Base.IOError} HTTP.post(
                "http://non.existent.host",
                ["Content-Length" => "5"],
                "Hello";
                retry=false,
                readtimeout=1,
                connect_timeout=1
            )
        end
    end
end

end # module
