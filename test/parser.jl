@testset "HTTP.parse" begin
reqstr = "GET http://www.techcrunch.com/ HTTP/1.1\r\n" *
         "Host: www.techcrunch.com\r\n" *
         "User-Agent: Fake\r\n" *
         "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n" *
         "Accept-Language: en-us,en;q=0.5\r\n" *
         "Accept-Encoding: gzip,deflate\r\n" *
         "Accept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.7\r\n" *
         "Keep-Alive: 300\r\n" *
         "Content-Length: 7\r\n" *
         "Proxy-Connection: keep-alive\r\n\r\n"

req = HTTP.Request("GET",
    HTTP.URI("http://www.techcrunch.com/"),
    Dict("Content-Length"=>"7","Host"=>"www.techcrunch.com","Accept"=>"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8","Accept-Charset"=>"ISO-8859-1,utf-8;q=0.7,*;q=0.7","Proxy-Connection"=>"keep-alive","Accept-Language"=>"en-us,en;q=0.5","Keep-Alive"=>"300","User-Agent"=>"Fake","Accept-Encoding"=>"gzip,deflate"),
    UInt8[]
)

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "GET / HTTP/1.1\r\n" *
         "Host: foo.com\r\n\r\n"

req = HTTP.Request()
req.uri = HTTP.URI("/")
req.headers = HTTP.Headers("Host"=>"foo.com")

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "GET //user@host/is/actually/a/path/ HTTP/1.1\r\n" *
         "Host: test\r\n\r\n"

req = HTTP.Request()
req.uri = HTTP.URI("//user@host/is/actually/a/path/")
req.headers = HTTP.Headers("Host"=>"test")

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "GET ../../../../etc/passwd HTTP/1.1\r\n" *
         "Host: test\r\n\r\n"

@test_throws HTTP.ParsingError HTTP.parse(HTTP.Request, reqstr)

reqstr = "GET  HTTP/1.1\r\n" *
         "Host: test\r\n\r\n"

@test_throws HTTP.ParsingError HTTP.parse(HTTP.Request, reqstr)

reqstr = "POST / HTTP/1.1\r\n" *
         "Host: foo.com\r\n" *
         "Transfer-Encoding: chunked\r\n\r\n" *
         "3\r\nfoo\r\n" *
         "3\r\nbar\r\n" *
         "0\r\n" *
         "Trailer-Key: Trailer-Value\r\n" *
         "\r\n"

req = HTTP.Request()
req.method = "POST"
req.uri = HTTP.URI("/")
req.headers = HTTP.Headers("Transfer-Encoding"=>"chunked", "Host"=>"foo.com", "Trailer-Key"=>"Trailer-Value")
req.body = HTTP.FIFOBuffer("foobar")

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "POST / HTTP/1.1\r\n" *
         "Host: foo.com\r\n" *
         "Transfer-Encoding: chunked\r\n" *
         "Content-Length: 9999\r\n\r\n" * # to be removed.
         "3\r\nfoo\r\n" *
         "3\r\nbar\r\n" *
         "0\r\n" *
         "\r\n"

@test_throws HTTP.ParsingError HTTP.parse(HTTP.Request, reqstr)

reqstr = "CONNECT www.google.com:443 HTTP/1.1\r\n\r\n"

req = HTTP.Request()
req.method = "CONNECT"
req.uri = HTTP.URI("www.google.com:443"; isconnect=true)

@test HTTP.parse(HTTP.Request, reqstr) == req

# reqstr = "CONNECT 127.0.0.1:6060 HTTP/1.1\r\n\r\n"
#
# req = HTTP.Request()
# req.method = "CONNECT"
# req.uri = HTTP.URI("127.0.0.1:6060")
#
# @test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "CONNECT /_goRPC_ HTTP/1.1\r\n\r\n"

req = HTTP.Request()
req.method = "CONNECT"
req.uri = HTTP.URI("/_goRPC_")

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "NOTIFY * HTTP/1.1\r\nServer: foo\r\n\r\n"

req = HTTP.Request()
req.method = "NOTIFY"
req.uri = HTTP.URI("*")
req.headers = HTTP.Headers("Server"=>"foo")

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "OPTIONS * HTTP/1.1\r\nServer: foo\r\n\r\n"

req = HTTP.Request()
req.method = "OPTIONS"
req.uri = HTTP.URI("*")
req.headers = HTTP.Headers("Server"=>"foo")

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "GET / HTTP/1.1\r\nHost: issue8261.com\r\nConnection: close\r\n\r\n"

req = HTTP.Request()
req.uri = HTTP.URI("/")
req.headers = HTTP.Headers("Host"=>"issue8261.com", "Connection"=>"close")

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "HEAD / HTTP/1.1\r\nHost: issue8261.com\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"

req = HTTP.Request()
req.method = "HEAD"
req.uri = HTTP.URI("/")
req.headers = HTTP.Headers("Host"=>"issue8261.com", "Connection"=>"close", "Content-Length"=>"0")

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "POST /cgi-bin/process.cgi HTTP/1.1\r\n" *
         "User-Agent: Mozilla/4.0 (compatible; MSIE5.01; Windows NT)\r\n" *
         "Host: www.tutorialspoint.com\r\n" *
         "Content-Type: text/xml; charset=utf-8\r\n" *
         "Content-Length: 19\r\n" *
         "Accept-Language: en-us\r\n" *
         "Accept-Encoding: gzip, deflate\r\n" *
         "Connection: Keep-Alive\r\n\r\n" *
         "first=Zara&last=Ali\r\n\r\n"

req = HTTP.Request()
req.method = "POST"
req.uri = HTTP.URI("/cgi-bin/process.cgi")
req.headers = HTTP.Headers("Host"=>"www.tutorialspoint.com",
                 "Connection"=>"Keep-Alive",
                 "Content-Length"=>"19",
                 "User-Agent"=>"Mozilla/4.0 (compatible; MSIE5.01; Windows NT)",
                 "Content-Type"=>"text/xml; charset=utf-8",
                 "Accept-Language"=>"en-us",
                 "Accept-Encoding"=>"gzip, deflate")
req.body = HTTP.FIFOBuffer("first=Zara&last=Ali")

@test HTTP.parse(HTTP.Request, reqstr) == req
end; # @testset "HTTP.parse"
