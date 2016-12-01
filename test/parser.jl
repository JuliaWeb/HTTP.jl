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
    1, 1,
    "http://www.techcrunch.com/",
    Dict("Content-Length"=>"7","Host"=>"www.techcrunch.com","Accept"=>"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8","Accept-Charset"=>"ISO-8859-1,utf-8;q=0.7,*;q=0.7","Proxy-Connection"=>"keep-alive","Accept-Language"=>"en-us,en;q=0.5","Keep-Alive"=>"300","User-Agent"=>"Fake","Accept-Encoding"=>"gzip,deflate"),
    true,
    UInt8[]
)

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "GET / HTTP/1.1\r\n" *
         "Host: foo.com\r\n\r\n"

req = HTTP.Request("GET",
    1, 1,
    "/", HTTP.Headers("Host"=>"foo.com"),
    true,
    UInt8[]
)

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "GET //user@host/is/actually/a/path/ HTTP/1.1\r\n" *
         "Host: test\r\n\r\n"

req = HTTP.Request("GET",
    1, 1,
    "//user@host/is/actually/a/path/",
    HTTP.Headers("Host"=>"test"),
    true,
    UInt8[]
)

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "GET ../../../../etc/passwd HTTP/1.1\r\n" *
         "Host: test\r\n\r\n"

@test_throws HTTP.ParserError HTTP.parse(HTTP.Request, reqstr)

reqstr = "GET  HTTP/1.1\r\n" *
         "Host: test\r\n\r\n"

@test_throws HTTP.ParserError HTTP.parse(HTTP.Request, reqstr)

reqstr = "POST / HTTP/1.1\r\n" *
         "Host: foo.com\r\n" *
         "Transfer-Encoding: chunked\r\n\r\n" *
         "3\r\nfoo\r\n" *
         "3\r\nbar\r\n" *
         "0\r\n" *
         "Trailer-Key: Trailer-Value\r\n" *
         "\r\n"

req = HTTP.Request("POST",
    1, 1,
    "/",
    HTTP.Headers("Transfer-Encoding"=>"chunked", "Host"=>"foo.com"),
    true,
    "foobar".data
)

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "POST / HTTP/1.1\r\n" *
         "Host: foo.com\r\n" *
         "Transfer-Encoding: chunked\r\n" *
         "Content-Length: 9999\r\n\r\n" * # to be removed.
         "3\r\nfoo\r\n" *
         "3\r\nbar\r\n" *
         "0\r\n" *
         "\r\n"

@test_throws HTTP.ParserError HTTP.parse(HTTP.Request, reqstr)

reqstr = "CONNECT www.google.com:443 HTTP/1.1\r\n\r\n"

req = HTTP.Request("CONNECT",
    1, 1,
    "www.google.com:443",
    HTTP.Headers(),
    true,
    UInt8[]
)

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "CONNECT 127.0.0.1:6060 HTTP/1.1\r\n\r\n"

req = HTTP.Request("CONNECT",
    1, 1,
    "127.0.0.1:6060",
    HTTP.Headers(),
    true,
    UInt8[]
)

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "CONNECT /_goRPC_ HTTP/1.1\r\n\r\n"

req = HTTP.Request("CONNECT",
    1, 1,
    "/_goRPC_",
    HTTP.Headers(),
    true,
    UInt8[]
)

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "NOTIFY * HTTP/1.1\r\nServer: foo\r\n\r\n"

req = HTTP.Request("NOTIFY",
    1, 1,
    "*",
    HTTP.Headers("Server"=>"foo"),
    true,
    UInt8[]
)

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "OPTIONS * HTTP/1.1\r\nServer: foo\r\n\r\n"

req = HTTP.Request("OPTIONS",
    1, 1,
    "*",
    HTTP.Headers("Server"=>"foo"),
    true,
    UInt8[]
)

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "GET / HTTP/1.1\r\nHost: issue8261.com\r\nConnection: close\r\n\r\n"

req = HTTP.Request("GET",
    1, 1,
    "/",
    HTTP.Headers("Host"=>"issue8261.com", "Connection"=>"close"),
    false,
    UInt8[]
)

@test HTTP.parse(HTTP.Request, reqstr) == req

reqstr = "HEAD / HTTP/1.1\r\nHost: issue8261.com\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"

req = HTTP.Request("HEAD",
    1, 1,
    "/",
    HTTP.Headers("Host"=>"issue8261.com", "Connection"=>"close", "Content-Length"=>"0"),
    false,
    UInt8[]
)

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

req = HTTP.Request("POST",
    1, 1,
    "/cgi-bin/process.cgi",
    HTTP.Headers("Host"=>"www.tutorialspoint.com",
                 "Connection"=>"Keep-Alive",
                 "Content-Length"=>"19",
                 "User-Agent"=>"Mozilla/4.0 (compatible; MSIE5.01; Windows NT)",
                 "Content-Type"=>"text/xml; charset=utf-8",
                 "Accept-Language"=>"en-us",
                 "Accept-Encoding"=>"gzip, deflate"),
    true,
    "first=Zara&last=Ali".data
)

@test HTTP.parse(HTTP.Request, reqstr) == req
