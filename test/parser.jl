using Test, HTTP, HTTP.Messages, HTTP.Parsers, HTTP.Strings
include(joinpath(dirname(pathof(HTTP)), "../test/resources/HTTPMessages.jl"))
using .HTTPMessages

import Base.==

const strict = false

==(a::Request,b::Request) = (a.method         == b.method)    &&
                            (a.version        == b.version)   &&
                            (a.headers        == b.headers)   &&
                            (a.body           == b.body)

macro errmsg(expr)
    esc(quote
        try
            $expr
        catch e
            sprint(show, e)
        end
    end)
end

@testset "HTTP.parser" begin
    @testset "parse - Strings" begin
        @testset "Requests - $request" for request in requests
            r = parse(Request, request.raw)
            
            if r.method == "CONNECT"
                host, port = split(r.target, ":")
                @test host == request.host
                @test port == request.port
            else
                if r.target == "*"
                    @test r.target == request.request_path
                else
                    target = parse(HTTP.URI, r.target)
                    @test target.query == request.query_string
                    @test target.fragment == request.fragment
                    @test target.path == request.request_path
                    @test target.host == request.host
                    @test target.userinfo == request.userinfo
                    @test target.port in (request.port, "80", "443")
                    @test string(target) == request.request_url
                end
            end

            r_headers = [tocameldash(n) => String(v) for (n,v) in r.headers]

            @test r.version.major == request.http_major
            @test r.version.minor == request.http_minor
            @test r.method == string(request.method)
            @test length(r.headers) == request.num_headers
            @test r_headers == request.headers
            @test String(r.body) == request.body

            @test_broken HTTP.http_should_keep_alive(HTTP.DEFAULT_PARSER) == request.should_keep_alive
            @test_broken String(collect(upgrade[])) == request.upgrade
        end

        @testset "Request - Headers" begin
            reqstr = "GET http://www.techcrunch.com/ HTTP/1.1\r\n" *
                   "Host: www.techcrunch.com\r\n" *
                   "User-Agent: Fake\r\n" *
                   "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n" *
                   "Accept-Language: en-us,en;q=0.5\r\n" *
                   "Accept-Encoding: gzip,deflate\r\n" *
                   "Accept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.7\r\n" *
                   "Keep-Alive: 300\r\n" *
                   "Content-Length: 7\r\n" *
                   "Proxy-Connection: keep-alive\r\n\r\n1234567"
            req = Request("GET", "http://www.techcrunch.com/", ["Host"=>"www.techcrunch.com","User-Agent"=>"Fake","Accept"=>"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8","Accept-Language"=>"en-us,en;q=0.5","Accept-Encoding"=>"gzip,deflate","Accept-Charset"=>"ISO-8859-1,utf-8;q=0.7,*;q=0.7","Keep-Alive"=>"300","Content-Length"=>"7","Proxy-Connection"=>"keep-alive"])
            req.body = HTTP.bytes("1234567")
            @test parse(Request,reqstr).headers == req.headers
            @test parse(Request,reqstr) == req  
        end

        @testset "Request - Hostname - URL" begin
            reqstr = "GET / HTTP/1.1\r\n" *
                   "Host: foo.com\r\n\r\n"
            req = Request("GET", "/", ["Host"=>"foo.com"])
            @test parse(Request, reqstr) == req  
        end

        @testset "Request - Hostname - Path" begin
            reqstr = "GET //user@host/is/actually/a/path/ HTTP/1.1\r\n" *
                   "Host: test\r\n\r\n"
            req = Request("GET", "//user@host/is/actually/a/path/",
                       ["Host"=>"test"])
            @test parse(Request, reqstr) == req        
        end

        @testset "Request - Hostname - Path - ParseError" begin
            reqstr = "GET  HTTP/1.1\r\n" *
                    "Host: test\r\n\r\n"
            @test_throws HTTP.ParseError parse(Request, reqstr)
        end

        @testset "Request - Hostname - URL - ParseError" begin
            reqstr = "GET ../../../../etc/passwd HTTP/1.1\r\n" *
                "Host: test\r\n\r\n"
            @test_throws HTTP.ParseError HTTP.URI(parse(Request, reqstr).target)
        end

        @testset "Request - HTTP - Bytes" begin
            reqstr = "POST / HTTP/1.1\r\n" *
                   "Host: foo.com\r\n" *
                   "Transfer-Encoding: chunked\r\n\r\n" *
                   "3\r\nfoo\r\n" *
                   "3\r\nbar\r\n" *
                   "0\r\n" *
                   "Trailer-Key: Trailer-Value\r\n" *
                   "\r\n"
            req = Request("POST", "/",
                        ["Host"=>"foo.com", "Transfer-Encoding"=>"chunked", "Trailer-Key"=>"Trailer-Value"])
            req.body = HTTP.bytes("foobar")
            @test parse(Request, reqstr) == req  
        end

        @test_skip @testset "Request - HTTP - ParseError" begin
            reqstr = "POST / HTTP/1.1\r\n" *
               "Host: foo.com\r\n" *
               "Transfer-Encoding: chunked\r\n" *
               "Content-Length: 9999\r\n\r\n" * # to be removed.
               "3\r\nfoo\r\n" *
               "3\r\nbar\r\n" *
               "0\r\n" *
               "\r\n"

            @test_throws HTTP.ParseError parse(Request, reqstr)
        end

        @testset "Request - URL" begin
            reqstr = "CONNECT www.google.com:443 HTTP/1.1\r\n\r\n"
            req = Request("CONNECT", "www.google.com:443")
            @test parse(Request, reqstr) == req  
        end

        @testset "Request - Localhost" begin
            reqstr = "CONNECT 127.0.0.1:6060 HTTP/1.1\r\n\r\n"
            req = Request("CONNECT", "127.0.0.1:6060")
            @test parse(Request, reqstr) == req  
        end

        @testset "Request - RPC" begin
            reqstr = "CONNECT /_goRPC_ HTTP/1.1\r\n\r\n"
            req = HTTP.Request("CONNECT", "/_goRPC_")
            @test parse(Request, reqstr) == req  
        end

        @testset "Request - NOTIFY" begin
            reqstr = "NOTIFY * HTTP/1.1\r\nServer: foo\r\n\r\n"
            req = Request("NOTIFY", "*", ["Server"=>"foo"])
            @test parse(Request, reqstr) == req
        end

        @testset "Request - OPTIONS" begin
            reqstr = "OPTIONS * HTTP/1.1\r\nServer: foo\r\n\r\n"
            req = Request("OPTIONS", "*", ["Server"=>"foo"])
            @test parse(Request, reqstr) == req
        end

        @testset "Request - GET" begin
            reqstr = "GET / HTTP/1.1\r\nHost: issue8261.com\r\nConnection: close\r\n\r\n"
            req = Request("GET", "/", ["Host"=>"issue8261.com", "Connection"=>"close"])
            @test parse(Request, reqstr) == req  
        end

        @testset "Request - HEAD" begin
            reqstr = "HEAD / HTTP/1.1\r\nHost: issue8261.com\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
            req = Request("HEAD", "/", ["Host"=>"issue8261.com", "Connection"=>"close", "Content-Length"=>"0"])
            @test parse(Request, reqstr) == req  
        end

        @testset "Request - POST" begin
            reqstr = "POST /cgi-bin/process.cgi HTTP/1.1\r\n" *
                   "User-Agent: Mozilla/4.0 (compatible; MSIE5.01; Windows NT)\r\n" *
                   "Host: www.tutorialspoint.com\r\n" *
                   "Content-Type: text/xml; charset=utf-8\r\n" *
                   "Content-Length: 19\r\n" *
                   "Accept-Language: en-us\r\n" *
                   "Accept-Encoding: gzip, deflate\r\n" *
                   "Connection: Keep-Alive\r\n\r\n" *
                   "first=Zara&last=Ali\r\n\r\n"
            req = Request("POST", "/cgi-bin/process.cgi",
                        ["User-Agent"=>"Mozilla/4.0 (compatible; MSIE5.01; Windows NT)",
                         "Host"=>"www.tutorialspoint.com",
                         "Content-Type"=>"text/xml; charset=utf-8",
                         "Content-Length"=>"19",
                         "Accept-Language"=>"en-us",
                         "Accept-Encoding"=>"gzip, deflate",
                         "Connection"=>"Keep-Alive"])
            req.body = HTTP.bytes("first=Zara&last=Ali")
            @test parse(Request, reqstr) == req
        end

        @testset "Request - Pair{}" begin
            r = parse(Request,"GET / HTTP/1.1\r\n" * "Test: Düsseldorf\r\n\r\n")
            @test Pair{String,String}[r.headers...] == ["Test" => "Düsseldorf"]
        end

        @testset "Request - Methods - 1" begin
            for m in ["GET", "PUT", "M-SEARCH", "FOOMETHOD"]
                r = parse(Request,"$m / HTTP/1.1\r\n\r\n")
                @test r.method == string(m)
            end
        end

        @testset "Request - Methods - 2" begin
            for m in ("ASDF","C******","COLA","GEM","GETA","M****","MKCOLA","PROPPATCHA","PUN","PX","SA")
                @test parse(Request,"$m / HTTP/1.1\r\n\r\n").method == m
            end            
        end

        @testset "Request - HTTPS" begin
            reqstr = "GET / HTTP/1.1\r\n" *
            "X-SSL-FoooBarr:   -----BEGIN CERTIFICATE-----\r\n" *
            "\tMIIFbTCCBFWgAwIBAgICH4cwDQYJKoZIhvcNAQEFBQAwcDELMAkGA1UEBhMCVUsx\r\n" *
            "\tETAPBgNVBAoTCGVTY2llbmNlMRIwEAYDVQQLEwlBdXRob3JpdHkxCzAJBgNVBAMT\r\n" *
            "\tAkNBMS0wKwYJKoZIhvcNAQkBFh5jYS1vcGVyYXRvckBncmlkLXN1cHBvcnQuYWMu\r\n" *
            "\tdWswHhcNMDYwNzI3MTQxMzI4WhcNMDcwNzI3MTQxMzI4WjBbMQswCQYDVQQGEwJV\r\n" *
            "\tSzERMA8GA1UEChMIZVNjaWVuY2UxEzARBgNVBAsTCk1hbmNoZXN0ZXIxCzAJBgNV\r\n" *
            "\tBAcTmrsogriqMWLAk1DMRcwFQYDVQQDEw5taWNoYWVsIHBhcmQYJKoZIhvcNAQEB\r\n" *
            "\tBQADggEPADCCAQoCggEBANPEQBgl1IaKdSS1TbhF3hEXSl72G9J+WC/1R64fAcEF\r\n" *
            "\tW51rEyFYiIeZGx/BVzwXbeBoNUK41OK65sxGuflMo5gLflbwJtHBRIEKAfVVp3YR\r\n" *
            "\tgW7cMA/s/XKgL1GEC7rQw8lIZT8RApukCGqOVHSi/F1SiFlPDxuDfmdiNzL31+sL\r\n" *
            "\t0iwHDdNkGjy5pyBSB8Y79dsSJtCW/iaLB0/n8Sj7HgvvZJ7x0fr+RQjYOUUfrePP\r\n" *
            "\tu2MSpFyf+9BbC/aXgaZuiCvSR+8Snv3xApQY+fULK/xY8h8Ua51iXoQ5jrgu2SqR\r\n" *
            "\twgA7BUi3G8LFzMBl8FRCDYGUDy7M6QaHXx1ZWIPWNKsCAwEAAaOCAiQwggIgMAwG\r\n" *
            "\tA1UdEwEB/wQCMAAwEQYJYIZIAYb4QgHTTPAQDAgWgMA4GA1UdDwEB/wQEAwID6DAs\r\n" *
            "\tBglghkgBhvhCAQ0EHxYdVUsgZS1TY2llbmNlIFVzZXIgQ2VydGlmaWNhdGUwHQYD\r\n" *
            "\tVR0OBBYEFDTt/sf9PeMaZDHkUIldrDYMNTBZMIGaBgNVHSMEgZIwgY+AFAI4qxGj\r\n" *
            "\tloCLDdMVKwiljjDastqooXSkcjBwMQswCQYDVQQGEwJVSzERMA8GA1UEChMIZVNj\r\n" *
            "\taWVuY2UxEjAQBgNVBAsTCUF1dGhvcml0eTELMAkGA1UEAxMCQ0ExLTArBgkqhkiG\r\n" *
            "\t9w0BCQEWHmNhLW9wZXJhdG9yQGdyaWQtc3VwcG9ydC5hYy51a4IBADApBgNVHRIE\r\n" *
            "\tIjAggR5jYS1vcGVyYXRvckBncmlkLXN1cHBvcnQuYWMudWswGQYDVR0gBBIwEDAO\r\n" *
            "\tBgwrBgEEAdkvAQEBAQYwPQYJYIZIAYb4QgEEBDAWLmh0dHA6Ly9jYS5ncmlkLXN1\r\n" *
            "\tcHBvcnQuYWMudmT4sopwqlBWsvcHViL2NybC9jYWNybC5jcmwwPQYJYIZIAYb4QgEDBDAWLmh0\r\n" *
            "\tdHA6Ly9jYS5ncmlkLXN1cHBvcnQuYWMudWsvcHViL2NybC9jYWNybC5jcmwwPwYD\r\n" *
            "\tVR0fBDgwNjA0oDKgMIYuaHR0cDovL2NhLmdyaWQt5hYy51ay9wdWIv\r\n" *
            "\tY3JsL2NhY3JsLmNybDANBgkqhkiG9w0BAQUFAAOCAQEAS/U4iiooBENGW/Hwmmd3\r\n" *
            "\tXCy6Zrt08YjKCzGNjorT98g8uGsqYjSxv/hmi0qlnlHs+k/3Iobc3LjS5AMYr5L8\r\n" *
            "\tUO7OSkgFFlLHQyC9JzPfmLCAugvzEbyv4Olnsr8hbxF1MbKZoQxUZtMVu29wjfXk\r\n" *
            "\thTeApBv7eaKCWpSp7MCbvgzm74izKhu3vlDk9w6qVrxePfGgpKPqfHiOoGhFnbTK\r\n" *
            "\twTC6o2xq5y0qZ03JonF7OJspEd3I5zKY3E+ov7/ZhW6DqT8UFvsAdjvQbXyhV8Eu\r\n" *
            "\tYhixw1aKEPzNjNowuIseVogKOLXxWI5vAi5HgXdS0/ES5gDGsABo4fqovUKlgop3\r\n" *
            "\tRA==\r\n" *
            "\t-----END CERTIFICATE-----\r\n" *
            "\r\n"

            r = parse(Request, reqstr)
            @test r.method == "GET"
            @test "GET / HTTP/1.1X-SSL-FoooBarr:   $(header(r, "X-SSL-FoooBarr"))" == replace(reqstr, "\r\n" => "")
            @test_throws HTTP.HTTP.ParseError HTTP.parse(Request, "GET / HTTP/1.1\r\nHost: www.example.com\r\nConnection\r\033\065\325eep-Alive\r\nAccept-Encoding: gzip\r\n\r\n")

            r = parse(Request,"GET /bad_get_no_headers_no_body/world HTTP/1.1\r\nAccept: */*\r\n\r\nHELLO")
            @test String(r.body) == ""
        end

        @testset "Response - readheaders() - 1" begin
            respstr = "HTTP/1.1 200 OK\r\n" * "Content-Length: " * "1844674407370955160" * "\r\n\r\n"
            r = Response()
            readheaders(IOBuffer(respstr), r)
            @test r.status == 200
            @test [r.headers...] == ["Content-Length"=>"1844674407370955160"]
        end

        @testset "Response - readheaders() - 2" begin
            respstr = "HTTP/1.1 200 OK\r\n" * "Transfer-Encoding: chunked\r\n\r\n" * "FFFFFFFFFFFFFFE" * "\r\n..."
            r = Response()
            readheaders(IOBuffer(respstr), r)
            @test r.status == 200
            @test [r.headers...] == ["Transfer-Encoding"=>"chunked"]
        end
    end

    @testset "parse - $response" for response in responses
        r = parse(Response, response.raw)
        r_headers = [tocameldash(n) => String(v) for (n,v) in r.headers]

        @test r.version.major == response.http_major
        @test r.version.minor == response.http_minor
        @test r.status == response.status_code
        @test HTTP.StatusCodes.statustext(r.status) == response.response_status
        @test length(r.headers) == response.num_headers
        @test r_headers == response.headers
        @test String(r.body) == response.body

        @test_skip @test HTTP.http_should_keep_alive(HTTP.DEFAULT_PARSER) == response.should_keep_alive
    end

    @testset "Parse Errors" begin
        @testset "Requests" begin
            @testset "ArgumentError - Invalid Base 10 Digit" begin
                reqstr = "GET / HTTP/1.1\r\n" * "Content-Length: 0\r\nContent-Length: 1\r\n\r\n"
                e = try parse(Request, reqstr) catch e e end
                @test isa(e, ArgumentError)
            end

            @testset "EOFError - 1" begin
                reqstr = "GET / HTTP/1.1\r\n" * "Transfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n"
                e = try parse(Request, reqstr) catch e e end
                @test isa(e, EOFError)
            end

            @testset "EOFError - 2" begin
                reqstr = "GET / HTTP/1.1\r\nheader: value\nhdr: value\r\n"
                e = try parse(Request, reqstr) catch e e end
                @test isa(e, EOFError)
            end

            @testset "Invalid Request Line" begin
                reqstr = "GET / HTP/1.1\r\n\r\n"
                e = try parse(Request, reqstr) catch e e end
                @test isa(e, HTTP.ParseError) && e.code ==:INVALID_REQUEST_LINE
            end

            @testset "Invalid Header Field - 1" begin
                reqstr = "GET / HTTP/1.1\r\n" * "Fo@: Failure\r\n\r\n"
                e = try parse(Request, reqstr) catch e e end
                @test isa(e, HTTP.ParseError) && e.code ==:INVALID_HEADER_FIELD
            end

            @testset "Invalid Header Field - 2" begin
                reqstr = "GET / HTTP/1.1\r\n" * "Foo\01\test: Bar\r\n\r\n"
                e = try parse(Request, reqstr) catch e e end
                @test isa(e, HTTP.ParseError) && e.code ==:INVALID_HEADER_FIELD
            end

            @testset "Invalid Header Field - 3" begin
                reqstr = "GET / HTTP/1.1\r\n" * "Foo: 1\rBar: 1\r\n\r\n"
                e = try parse(Request, reqstr) catch e e end
                @test isa(e, HTTP.ParseError) && e.code ==:INVALID_HEADER_FIELD
            end

            @testset "Invalid Header Field - 4" begin
                reqstr = "GET / HTTP/1.1\r\n" * "name\r\n" * " : value\r\n\r\n"
                e = try parse(Request, reqstr) catch e e end
                @test isa(e, HTTP.ParseError) && e.code ==:INVALID_HEADER_FIELD
            end

            @testset "Invalid Request Line" begin
                for m in ("HTTP/1.1", "hello world")
                    reqstr = "$m / HTTP/1.1\r\n\r\n"
                    e = try parse(Request, reqstr) catch e e end
                    @test isa(e, HTTP.ParseError) && e.code ==:INVALID_REQUEST_LINE
                end
            end

            @testset "Strict Headers - 1" begin
                reqstr = "GET / HTTP/1.1\r\n" * "Foo: F\01ailure\r\n\r\n"
                strict && @test_throws HTTP.ParseError parse(Request,reqstr)
                
                if !strict
                    r = HTTP.parse(HTTP.Messages.Request, reqstr)
                    @test r.method == "GET"
                    @test r.target == "/"
                    @test length(r.headers) == 1
                end
            end

            @testset "Strict Headers - 2" begin
                reqstr = "GET / HTTP/1.1\r\n" * "Foo: B\02ar\r\n\r\n"
                strict && @test_throws HTTP.ParseError parse(Request, reqstr)
                
                if !strict
                    r = parse(HTTP.Messages.Request, reqstr)
                    @test r.method == "GET"
                    @test r.target == "/"
                    @test length(r.headers) == 1
                end
            end

            # https://github.com/JuliaWeb/HTTP.jl/issues/796
            @testset "Latin-1 values in header" begin
                reqstr = "GET / HTTP/1.1\r\n" * "link: <http://dx.doi.org/10.1016/j.cma.2021.114093>; rel=\"canonical\", <https://api.elsevier.com/content/article/PII:S0045782521004242?httpAccept=text/xml>; version=\"vor\"; type=\"text/xml\"; rel=\"item\", <https://api.elsevier.com/content/article/PII:S0045782521004242?httpAccept=text/plain>; version=\"vor\"; type=\"text/plain\"; rel=\"item\", <https://www.elsevier.com/tdm/userlicense/1.0/>; version=\"tdm\"; rel=\"license\", <http://orcid.org/0000-0003-2391-4086>; title=\"Santiago Badia\"; rel=\"author\", <http://orcid.org/0000-0001-5751-4561>; title=\"Alberto F. Mart\xedn\"; rel=\"author\"\r\n\r\n"
                r = parse(HTTP.Messages.Request, reqstr)
                @test r.method == "GET"
                @test r.target == "/"
                @test length(r.headers) == 1
                @test r.headers[1][2] == "<http://dx.doi.org/10.1016/j.cma.2021.114093>; rel=\"canonical\", <https://api.elsevier.com/content/article/PII:S0045782521004242?httpAccept=text/xml>; version=\"vor\"; type=\"text/xml\"; rel=\"item\", <https://api.elsevier.com/content/article/PII:S0045782521004242?httpAccept=text/plain>; version=\"vor\"; type=\"text/plain\"; rel=\"item\", <https://www.elsevier.com/tdm/userlicense/1.0/>; version=\"tdm\"; rel=\"license\", <http://orcid.org/0000-0003-2391-4086>; title=\"Santiago Badia\"; rel=\"author\", <http://orcid.org/0000-0001-5751-4561>; title=\"Alberto F. Martín\"; rel=\"author\""
            end
        end

        @testset "Responses" begin
            @testset "ArgumentError - Invalid Base 10 Digit" begin
                respstr = "HTTP/1.1 200 OK\r\n" * "Content-Length: 0\r\nContent-Length: 1\r\n\r\n"
                e = try parse(Response, respstr) catch e e end
                @test isa(e, ArgumentError)
            end

            @testset "Chunk Size Exceeds Limit" begin
                respstr = "HTTP/1.1 200 OK\r\n" * "Transfer-Encoding: chunked\r\n\r\n" * "FFFFFFFFFFFFFFF" * "\r\n..."
                e = try parse(Response,respstr) catch e e end
                @test isa(e, HTTP.ParseError) && e.code == :CHUNK_SIZE_EXCEEDS_LIMIT
            end

            @testset "Chunk Size Exceeds Limit" begin
                respstr = "HTTP/1.1 200 OK\r\n" * "Transfer-Encoding: chunked\r\n\r\n" * "10000000000000000" * "\r\n..."
                e = try parse(Response,respstr) catch e e end
                @test isa(e, HTTP.ParseError) && e.code == :CHUNK_SIZE_EXCEEDS_LIMIT
            end

            @testset "EOF Error" begin
                respstr = "HTTP/1.1 200 OK\r\n" * "Transfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n"
                e = try parse(Response, respstr) catch e e end
                @test isa(e, EOFError)
            end

            @test_skip @testset "Invalid Content Length" begin
                respstr = "HTTP/1.1 200 OK\r\n" * "Content-Length: " * "18446744073709551615" * "\r\n\r\n"
                e = try parse(Response,respstr) catch e e end
                @test isa(e, HTTP.ParseError) && e.code == Parsers.HPE_INVALID_CONTENT_LENGTH
            end

            @testset "Invalid Header Field - 1" begin
                respstr = "HTTP/1.1 200 OK\r\n" * "Fo@: Failure\r\n\r\n"
                e = try parse(Response, respstr) catch e e end
                @test isa(e, HTTP.ParseError) && e.code ==:INVALID_HEADER_FIELD
            end

            @testset "Invalid Header Field - 2" begin
                respstr = "HTTP/1.1 200 OK\r\n" * "Foo\01\test: Bar\r\n\r\n"
                e = try parse(Response, respstr) catch e e end
                @test isa(e, HTTP.ParseError) && e.code ==:INVALID_HEADER_FIELD
            end

            @testset "Invalid Header Field - 3" begin
                respstr = "HTTP/1.1 200 OK\r\n" * "Foo: 1\rBar: 1\r\n\r\n"
                e = try parse(Response, respstr) catch e e end
                @test isa(e, HTTP.ParseError) && e.code ==:INVALID_HEADER_FIELD
            end

            @testset "Strict Headers - 1" begin
                respstr = "HTTP/1.1 200 OK\r\n" * "Foo: F\01ailure\r\n\r\n"
                strict && @test_throws HTTP.ParseError parse(Response,respstr)
                
                if !strict
                    r = parse(HTTP.Messages.Response, respstr)
                    @test r.status == 200
                    @test length(r.headers) == 1
                end
            end

            @testset "Strict Headers - 2" begin
                respstr = "HTTP/1.1 200 OK\r\n" * "Foo: B\02ar\r\n\r\n"
                strict && @test_throws HTTP.ParseError parse(Response,respstr)
                
                if !strict
                    r = parse(HTTP.Messages.Response, respstr)
                    @test r.status == 200
                    @test length(r.headers) == 1
                end
            end
        end
    end
end
