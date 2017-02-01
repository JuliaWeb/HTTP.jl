#= Copyright Joyent, Inc. and other Node contributors. All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to
 * deal in the Software without restriction, including without limitation the
 * rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
 * sell copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 =#

using HTTP, Base.Test

const MAX_HEADERS = 13
const MAX_ELEMENT_SIZE = 2048
const MAX_CHUNKS = 16

type Message
    name::String
    raw::String
    method::HTTP.Method
    status_code::Int
    response_status::String
    request_path::String
    request_url::String
    fragment::String
    query_string::String
    body::String
    body_size::Int
    host::String
    userinfo::String
    port::String
    num_headers::Int
    headers::Dict{String,String}
    should_keep_alive::Bool
    upgrade::String
    http_major::Int
    http_minor::Int

    Message(name::String) = new(name, "", HTTP.GET, 200, "", "", "", "", "", "", 0, "", "", "", 0, HTTP.Headers(), true, "", 1, 1)
end

function Message(; name::String="", kwargs...)
    m = Message(name)
    for (k, v) in kwargs
        try
            setfield!(m, k, v)
        catch e
            error("error setting k=$k, v=$v")
        end
    end
    return m
end

#= * R E Q U E S T S * =#
const requests = Message[
  Message(name= "curl get"
  ,raw= "GET /test HTTP/1.1\r\n" *
         "User-Agent: curl/7.18.0 (i486-pc-linux-gnu) libcurl/7.18.0 OpenSSL/0.9.8g zlib/1.2.3.3 libidn/1.1\r\n" *
         "Host: 0.0.0.0=5000\r\n" *
         "Accept: */*\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/test"
  ,request_url= "/test"
  ,num_headers= 3
  ,headers=Dict{String,String}(
      "User-Agent"=> "curl/7.18.0 (i486-pc-linux-gnu) libcurl/7.18.0 OpenSSL/0.9.8g zlib/1.2.3.3 libidn/1.1"
    , "Host"=> "0.0.0.0=5000"
    , "Accept"=> "*/*"
    )
  ,body= ""
), Message(name= "firefox get"
  ,raw= "GET /favicon.ico HTTP/1.1\r\n" *
         "Host: 0.0.0.0=5000\r\n" *
         "User-Agent: Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9) Gecko/2008061015 Firefox/3.0\r\n" *
         "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n" *
         "Accept-Language: en-us,en;q=0.5\r\n" *
         "Accept-Encoding: gzip,deflate\r\n" *
         "Accept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.7\r\n" *
         "Keep-Alive: 300\r\n" *
         "Connection: keep-alive\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/favicon.ico"
  ,request_url= "/favicon.ico"
  ,num_headers= 8
  ,headers=Dict{String,String}(
      "Host"=> "0.0.0.0=5000"
    , "User-Agent"=> "Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9) Gecko/2008061015 Firefox/3.0"
    , "Accept"=> "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    , "Accept-Language"=> "en-us,en;q=0.5"
    , "Accept-Encoding"=> "gzip,deflate"
    , "Accept-Charset"=> "ISO-8859-1,utf-8;q=0.7,*;q=0.7"
    , "Keep-Alive"=> "300"
    , "Connection"=> "keep-alive"
  )
  ,body= ""
), Message(name= "dumbfuck"
  ,raw= "GET /dumbfuck HTTP/1.1\r\n" *
         "aaaaaaaaaaaaa:++++++++++\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/dumbfuck"
  ,request_url= "/dumbfuck"
  ,num_headers= 1
  ,headers=Dict{String,String}(
      "aaaaaaaaaaaaa"=>  "++++++++++"
  )
  ,body= ""
), Message(name= "fragment in url"
  ,raw= "GET /forums/1/topics/2375?page=1#posts-17408 HTTP/1.1\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= "page=1"
  ,fragment= "posts-17408"
  ,request_path= "/forums/1/topics/2375"
  #= XXX request url does include fragment? =#
  ,request_url= "/forums/1/topics/2375?page=1#posts-17408"
  ,num_headers= 0
  ,body= ""
), Message(name= "get no headers no body"
  ,raw= "GET /get_no_headers_no_body/world HTTP/1.1\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/get_no_headers_no_body/world"
  ,request_url= "/get_no_headers_no_body/world"
  ,num_headers= 0
  ,body= ""
), Message(name= "get one header no body"
  ,raw= "GET /get_one_header_no_body HTTP/1.1\r\n" *
         "Accept: */*\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/get_one_header_no_body"
  ,request_url= "/get_one_header_no_body"
  ,num_headers= 1
  ,headers=Dict{String,String}(
       "Accept" => "*/*"
  )
  ,body= ""
), Message(name= "get funky content length body hello"
  ,raw= "GET /get_funky_content_length_body_hello HTTP/1.0\r\n" *
         "conTENT-Length: 5\r\n" *
         "\r\n" *
         "HELLO"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 0
  ,method= HTTP.GET
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/get_funky_content_length_body_hello"
  ,request_url= "/get_funky_content_length_body_hello"
  ,num_headers= 1
  ,headers=Dict{String,String}(
       "conTENT-Length" => "5"
  )
  ,body= "HELLO"
), Message(name= "post identity body world"
  ,raw= "POST /post_identity_body_world?q=search#hey HTTP/1.1\r\n" *
         "Accept: */*\r\n" *
         "Transfer-Encoding: identity\r\n" *
         "Content-Length: 5\r\n" *
         "\r\n" *
         "World"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.POST
  ,query_string= "q=search"
  ,fragment= "hey"
  ,request_path= "/post_identity_body_world"
  ,request_url= "/post_identity_body_world?q=search#hey"
  ,num_headers= 3
  ,headers=Dict{String,String}(
      "Accept"=> "*/*"
    , "Transfer-Encoding"=> "identity"
    , "Content-Length"=> "5"
  )
  ,body= "World"
), Message(name= "post - chunked body: all your base are belong to us"
  ,raw= "POST /post_chunked_all_your_base HTTP/1.1\r\n" *
         "Transfer-Encoding: chunked\r\n" *
         "\r\n" *
         "1e\r\nall your base are belong to us\r\n" *
         "0\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.POST
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/post_chunked_all_your_base"
  ,request_url= "/post_chunked_all_your_base"
  ,num_headers= 1
  ,headers=Dict{String,String}(
      "Transfer-Encoding" => "chunked"
  )
  ,body= "all your base are belong to us"
), Message(name= "two chunks ; triple zero ending"
  ,raw= "POST /two_chunks_mult_zero_end HTTP/1.1\r\n" *
         "Transfer-Encoding: chunked\r\n" *
         "\r\n" *
         "5\r\nhello\r\n" *
         "6\r\n world\r\n" *
         "000\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.POST
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/two_chunks_mult_zero_end"
  ,request_url= "/two_chunks_mult_zero_end"
  ,num_headers= 1
  ,headers=Dict{String,String}(
      "Transfer-Encoding"=> "chunked"
  )
  ,body= "hello world"
), Message(name= "chunked with trailing headers. blech."
  ,raw= "POST /chunked_w_trailing_headers HTTP/1.1\r\n" *
         "Transfer-Encoding: chunked\r\n" *
         "\r\n" *
         "5\r\nhello\r\n" *
         "6\r\n world\r\n" *
         "0\r\n" *
         "Vary: *\r\n" *
         "Content-Type: text/plain\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.POST
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/chunked_w_trailing_headers"
  ,request_url= "/chunked_w_trailing_headers"
  ,num_headers= 3
  ,headers=Dict{String,String}(
      "Transfer-Encoding"=>  "chunked"
    , "Vary"=> "*"
    , "Content-Type"=> "text/plain"
  )
  ,body= "hello world"
), Message(name= "with bullshit after the length"
  ,raw= "POST /chunked_w_bullshit_after_length HTTP/1.1\r\n" *
         "Transfer-Encoding: chunked\r\n" *
         "\r\n" *
         "5; ihatew3;whatthefuck=aretheseparametersfor\r\nhello\r\n" *
         "6; blahblah; blah\r\n world\r\n" *
         "0\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.POST
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/chunked_w_bullshit_after_length"
  ,request_url= "/chunked_w_bullshit_after_length"
  ,num_headers= 1
  ,headers=Dict{String,String}(
      "Transfer-Encoding"=> "chunked"
  )
  ,body= "hello world"
), Message(name= "with quotes"
  ,raw= "GET /with_\"stupid\"_quotes?foo=\"bar\" HTTP/1.1\r\n\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= "foo=\"bar\""
  ,fragment= ""
  ,request_path= "/with_\"stupid\"_quotes"
  ,request_url= "/with_\"stupid\"_quotes?foo=\"bar\""
  ,num_headers= 0
  ,headers=Dict{String,String}()
  ,body= ""
), Message(name = "apachebench get"
  ,raw= "GET /test HTTP/1.0\r\n" *
         "Host: 0.0.0.0:5000\r\n" *
         "User-Agent: ApacheBench/2.3\r\n" *
         "Accept: */*\r\n\r\n"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 0
  ,method= HTTP.GET
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/test"
  ,request_url= "/test"
  ,num_headers= 3
  ,headers=Dict{String,String}( "Host"=> "0.0.0.0:5000"
             , "User-Agent"=> "ApacheBench/2.3"
             , "Accept"=> "*/*"
           )
  ,body= ""
), Message(name = "query url with question mark"
  ,raw= "GET /test.cgi?foo=bar?baz HTTP/1.1\r\n\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= "foo=bar?baz"
  ,fragment= ""
  ,request_path= "/test.cgi"
  ,request_url= "/test.cgi?foo=bar?baz"
  ,num_headers= 0
  ,headers=Dict{String,String}()
  ,body= ""
), Message(name = "newline prefix get"
  ,raw= "\r\nGET /test HTTP/1.1\r\n\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/test"
  ,request_url= "/test"
  ,num_headers= 0
  ,headers=Dict{String,String}()
  ,body= ""
), Message(name = "upgrade request"
  ,raw= "GET /demo HTTP/1.1\r\n" *
         "Host: example.com\r\n" *
         "Connection: Upgrade\r\n" *
         "Sec-WebSocket-Key2: 12998 5 Y3 1  .P00\r\n" *
         "Sec-WebSocket-Protocol: sample\r\n" *
         "Upgrade: WebSocket\r\n" *
         "Sec-WebSocket-Key1: 4 @1  46546xW%0l 1 5\r\n" *
         "Origin: http://example.com\r\n" *
         "\r\n" *
         "Hot diggity dogg"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/demo"
  ,request_url= "/demo"
  ,num_headers= 7
  ,upgrade="Hot diggity dogg"
  ,headers=Dict{String,String}( "Host"=> "example.com"
             , "Connection"=> "Upgrade"
             , "Sec-WebSocket-Key2"=> "12998 5 Y3 1  .P00"
             , "Sec-WebSocket-Protocol"=> "sample"
             , "Upgrade"=> "WebSocket"
             , "Sec-WebSocket-Key1"=> "4 @1  46546xW%0l 1 5"
             , "Origin"=> "http://example.com"
           )
  ,body= ""
), Message(name = "connect request"
  ,raw= "CONNECT 0-home0.netscape.com:443 HTTP/1.0\r\n" *
         "User-agent: Mozilla/1.1N\r\n" *
         "Proxy-authorization: basic aGVsbG86d29ybGQ=\r\n" *
         "\r\n" *
         "some data\r\n" *
         "and yet even more data"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 0
  ,method= HTTP.CONNECT
  ,query_string= ""
  ,fragment= ""
  ,request_path= ""
  ,host="0-home0.netscape.com"
  ,port="443"
  ,request_url= "0-home0.netscape.com:443"
  ,num_headers= 2
  ,upgrade="some data\r\nand yet even more data"
  ,headers=Dict{String,String}( "User-agent"=> "Mozilla/1.1N"
             , "Proxy-authorization"=> "basic aGVsbG86d29ybGQ="
           )
  ,body= ""
), Message(name= "report request"
  ,raw= "REPORT /test HTTP/1.1\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.REPORT
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/test"
  ,request_url= "/test"
  ,num_headers= 0
  ,headers=Dict{String,String}()
  ,body= ""
), Message(name= "request with no http version"
  ,raw= "GET /\r\n" *
         "\r\n"
  ,should_keep_alive= false
  ,http_major= 0
  ,http_minor= 9
  ,method= HTTP.GET
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/"
  ,request_url= "/"
  ,num_headers= 0
  ,headers=Dict{String,String}()
  ,body= ""
), Message(name= "m-search request"
  ,raw= "M-SEARCH * HTTP/1.1\r\n" *
         "HOST: 239.255.255.250:1900\r\n" *
         "MAN: \"ssdp:discover\"\r\n" *
         "ST: \"ssdp:all\"\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.MSEARCH
  ,query_string= ""
  ,fragment= ""
  ,request_path= "*"
  ,request_url= "*"
  ,num_headers= 3
  ,headers=Dict{String,String}( "HOST"=> "239.255.255.250:1900"
             , "MAN"=> "\"ssdp:discover\""
             , "ST"=> "\"ssdp:all\""
           )
  ,body= ""
), Message(name= "host terminated by a query string"
  ,raw= "GET http://hypnotoad.org?hail=all HTTP/1.1\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= "hail=all"
  ,fragment= ""
  ,request_path= ""
  ,request_url= "http://hypnotoad.org?hail=all"
  ,host= "hypnotoad.org"
  ,num_headers= 0
  ,headers=Dict{String,String}()
  ,body= ""
), Message(name= "host:port terminated by a query string"
  ,raw= "GET http://hypnotoad.org:1234?hail=all HTTP/1.1\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= "hail=all"
  ,fragment= ""
  ,request_path= ""
  ,request_url= "http://hypnotoad.org:1234?hail=all"
  ,host= "hypnotoad.org"
  ,port= "1234"
  ,num_headers= 0
  ,headers=Dict{String,String}()
  ,body= ""
), Message(name= "host:port terminated by a space"
  ,raw= "GET http://hypnotoad.org:1234 HTTP/1.1\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= ""
  ,fragment= ""
  ,request_path= ""
  ,request_url= "http://hypnotoad.org:1234"
  ,host= "hypnotoad.org"
  ,port= "1234"
  ,num_headers= 0
  ,headers=Dict{String,String}()
  ,body= ""
), Message(name = "PATCH request"
  ,raw= "PATCH /file.txt HTTP/1.1\r\n" *
         "Host: www.example.com\r\n" *
         "Content-Type: application/example\r\n" *
         "If-Match: \"e0023aa4e\"\r\n" *
         "Content-Length: 10\r\n" *
         "\r\n" *
         "cccccccccc"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.PATCH
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/file.txt"
  ,request_url= "/file.txt"
  ,num_headers= 4
  ,headers=Dict{String,String}( "Host"=> "www.example.com"
             , "Content-Type"=> "application/example"
             , "If-Match"=> "\"e0023aa4e\""
             , "Content-Length"=> "10"
           )
  ,body= "cccccccccc"
), Message(name = "connect caps request"
  ,raw= "CONNECT HOME0.NETSCAPE.COM:443 HTTP/1.0\r\n" *
         "User-agent: Mozilla/1.1N\r\n" *
         "Proxy-authorization: basic aGVsbG86d29ybGQ=\r\n" *
         "\r\n"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 0
  ,method= HTTP.CONNECT
  ,query_string= ""
  ,fragment= ""
  ,request_path= ""
  ,request_url= "HOME0.NETSCAPE.COM:443"
  ,host="HOME0.NETSCAPE.COM"
  ,port="443"
  ,num_headers= 2
  ,upgrade=""
  ,headers=Dict{String,String}( "User-agent"=> "Mozilla/1.1N"
             , "Proxy-authorization"=> "basic aGVsbG86d29ybGQ="
           )
  ,body= ""
), Message(name= "utf-8 path request"
  ,raw= "GET /δ¶/δt/pope?q=1#narf HTTP/1.1\r\n" *
         "Host: github.com\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= "q=1"
  ,fragment= "narf"
  ,request_path= "/δ¶/δt/pope"
  ,request_url= "/δ¶/δt/pope?q=1#narf"
  ,num_headers= 1
  ,headers=Dict{String,String}("Host" => "github.com")
  ,body= ""
), Message(name = "hostname underscore"
  ,raw= "CONNECT home_0.netscape.com:443 HTTP/1.0\r\n" *
         "User-agent: Mozilla/1.1N\r\n" *
         "Proxy-authorization: basic aGVsbG86d29ybGQ=\r\n" *
         "\r\n"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 0
  ,method= HTTP.CONNECT
  ,query_string= ""
  ,fragment= ""
  ,request_path= ""
  ,request_url= "home_0.netscape.com:443"
  ,host="home_0.netscape.com"
  ,port="443"
  ,num_headers= 2
  ,upgrade=""
  ,headers=Dict{String,String}( "User-agent"=> "Mozilla/1.1N"
             , "Proxy-authorization"=> "basic aGVsbG86d29ybGQ="
           )
  ,body= ""
), Message(name = "eat CRLF between requests, no \"Connection: close\" header"
  ,raw= "POST / HTTP/1.1\r\n" *
         "Host: www.example.com\r\n" *
         "Content-Type: application/x-www-form-urlencoded\r\n" *
         "Content-Length: 4\r\n" *
         "\r\n" *
         "q=42\r\n" #= note the trailing CRLF =#
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.POST
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/"
  ,request_url= "/"
  ,num_headers= 3
  ,upgrade= ""
  ,headers=Dict{String,String}( "Host"=> "www.example.com"
             , "Content-Type"=> "application/x-www-form-urlencoded"
             , "Content-Length"=> "4"
           )
  ,body= "q=42"
), Message(name = "eat CRLF between requests even if \"Connection: close\" is set"
  ,raw= "POST / HTTP/1.1\r\n" *
         "Host: www.example.com\r\n" *
         "Content-Type: application/x-www-form-urlencoded\r\n" *
         "Content-Length: 4\r\n" *
         "Connection: close\r\n" *
         "\r\n" *
         "q=42\r\n" #= note the trailing CRLF =#
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.POST
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/"
  ,request_url= "/"
  ,num_headers= 4
  ,upgrade= ""
  ,headers=Dict{String,String}( "Host"=> "www.example.com"
             , "Content-Type"=> "application/x-www-form-urlencoded"
             , "Content-Length"=> "4"
             , "Connection"=> "close"
           )
  ,body= "q=42"
), Message(name = "PURGE request"
  ,raw= "PURGE /file.txt HTTP/1.1\r\n" *
         "Host: www.example.com\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.PURGE
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/file.txt"
  ,request_url= "/file.txt"
  ,num_headers= 1
  ,headers=Dict{String,String}( "Host"=> "www.example.com" )
  ,body= ""
), Message(name = "SEARCH request"
  ,raw= "SEARCH / HTTP/1.1\r\n" *
         "Host: www.example.com\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.SEARCH
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/"
  ,request_url= "/"
  ,num_headers= 1
  ,headers=Dict{String,String}( "Host"=> "www.example.com")
  ,body= ""
), Message(name= "host:port and basic_auth"
  ,raw= "GET http://a%12:b!&*\$@hypnotoad.org:1234/toto HTTP/1.1\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,fragment= ""
  ,request_path= "/toto"
  ,request_url= "http://a%12:b!&*\$@hypnotoad.org:1234/toto"
  ,host= "hypnotoad.org"
  ,userinfo= "a%12:b!&*\$"
  ,port= "1234"
  ,num_headers= 0
  ,headers=Dict{String,String}()
  ,body= ""
), Message(name = "upgrade post request"
  ,raw= "POST /demo HTTP/1.1\r\n" *
         "Host: example.com\r\n" *
         "Connection: Upgrade\r\n" *
         "Upgrade: HTTP/2.0\r\n" *
         "Content-Length: 15\r\n" *
         "\r\n" *
         "sweet post body" *
         "Hot diggity dogg"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.POST
  ,request_path= "/demo"
  ,request_url= "/demo"
  ,num_headers= 4
  ,upgrade="Hot diggity dogg"
  ,headers=Dict{String,String}( "Host"=> "example.com"
             , "Connection"=> "Upgrade"
             , "Upgrade"=> "HTTP/2.0"
             , "Content-Length"=> "15"
           )
  ,body= "sweet post body"
), Message(name = "connect with body request"
  ,raw= "CONNECT foo.bar.com:443 HTTP/1.0\r\n" *
         "User-agent: Mozilla/1.1N\r\n" *
         "Proxy-authorization: basic aGVsbG86d29ybGQ=\r\n" *
         "Content-Length: 10\r\n" *
         "\r\n" *
         "blarfcicle"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 0
  ,method= HTTP.CONNECT
  ,request_url= "foo.bar.com:443"
  ,host="foo.bar.com"
  ,port="443"
  ,num_headers= 3
  ,upgrade="blarfcicle"
  ,headers=Dict{String,String}( "User-agent"=> "Mozilla/1.1N"
             , "Proxy-authorization"=> "basic aGVsbG86d29ybGQ="
             , "Content-Length"=> "10"
           )
  ,body= ""
), Message(name = "link request"
  ,raw= "LINK /images/my_dog.jpg HTTP/1.1\r\n" *
         "Host: example.com\r\n" *
         "Link: <http://example.com/profiles/joe>; rel=\"tag\"\r\n" *
         "Link: <http://example.com/profiles/sally>; rel=\"tag\"\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.LINK
  ,request_path= "/images/my_dog.jpg"
  ,request_url= "/images/my_dog.jpg"
  ,query_string= ""
  ,fragment= ""
  ,num_headers= 2
  ,headers=Dict{String,String}( "Host"=> "example.com"
             , "Link"=> "<http://example.com/profiles/joe>; rel=\"tag\", <http://example.com/profiles/sally>; rel=\"tag\""
           )
  ,body= ""
), Message(name = "link request"
  ,raw= "UNLINK /images/my_dog.jpg HTTP/1.1\r\n" *
         "Host: example.com\r\n" *
         "Link: <http://example.com/profiles/sally>; rel=\"tag\"\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.UNLINK
  ,request_path= "/images/my_dog.jpg"
  ,request_url= "/images/my_dog.jpg"
  ,query_string= ""
  ,fragment= ""
  ,num_headers= 2
  ,headers=Dict{String,String}( "Host"=> "example.com"
	     , "Link"=> "<http://example.com/profiles/sally>; rel=\"tag\""
           )
  ,body= ""
), Message(name = "multiple connection header values with folding"
  ,raw= "GET /demo HTTP/1.1\r\n" *
         "Host: example.com\r\n" *
         "Connection: Something,\r\n" *
         " Upgrade, ,Keep-Alive\r\n" *
         "Sec-WebSocket-Key2: 12998 5 Y3 1  .P00\r\n" *
         "Sec-WebSocket-Protocol: sample\r\n" *
         "Upgrade: WebSocket\r\n" *
         "Sec-WebSocket-Key1: 4 @1  46546xW%0l 1 5\r\n" *
         "Origin: http://example.com\r\n" *
         "\r\n" *
         "Hot diggity dogg"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/demo"
  ,request_url= "/demo"
  ,num_headers= 7
  ,upgrade="Hot diggity dogg"
  ,headers=Dict{String,String}( "Host"=> "example.com"
             , "Connection"=> "Something, Upgrade, ,Keep-Alive"
             , "Sec-WebSocket-Key2"=> "12998 5 Y3 1  .P00"
             , "Sec-WebSocket-Protocol"=> "sample"
             , "Upgrade"=> "WebSocket"
             , "Sec-WebSocket-Key1"=> "4 @1  46546xW%0l 1 5"
             , "Origin"=> "http://example.com"
           )
  ,body= ""
), Message(name= "line folding in header value"
  ,raw= "GET / HTTP/1.1\r\n" *
         "Line1:   abc\r\n" *
         "\tdef\r\n" *
         " ghi\r\n" *
         "\t\tjkl\r\n" *
         "  mno \r\n" *
         "\t \tqrs\r\n" *
         "Line2: \t line2\t\r\n" *
         "Line3:\r\n" *
         " line3\r\n" *
         "Line4: \r\n" *
         " \r\n" *
         "Connection:\r\n" *
         " close\r\n" *
         "\r\n"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/"
  ,request_url= "/"
  ,num_headers= 5
  ,headers=Dict{String,String}( "Line1"=> "abc\tdef ghi\t\tjkl  mno \t \tqrs"
             , "Line2"=> "line2\t"
             , "Line3"=> "line3"
             , "Line4"=> ""
             , "Connection"=> "close"
           )
  ,body= ""
), Message(name = "multiple connection header values with folding and lws"
  ,raw= "GET /demo HTTP/1.1\r\n" *
         "Connection: keep-alive, upgrade\r\n" *
         "Upgrade: WebSocket\r\n" *
         "\r\n" *
         "Hot diggity dogg"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/demo"
  ,request_url= "/demo"
  ,num_headers= 2
  ,upgrade="Hot diggity dogg"
  ,headers=Dict{String,String}( "Connection"=> "keep-alive, upgrade"
             , "Upgrade"=> "WebSocket"
           )
  ,body= ""
), Message(name = "multiple connection header values with folding and lws"
  ,raw= "GET /demo HTTP/1.1\r\n" *
         "Connection: keep-alive, \r\n upgrade\r\n" *
         "Upgrade: WebSocket\r\n" *
         "\r\n" *
         "Hot diggity dogg"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/demo"
  ,request_url= "/demo"
  ,num_headers= 2
  ,upgrade="Hot diggity dogg"
  ,headers=Dict{String,String}( "Connection"=> "keep-alive,  upgrade"
             , "Upgrade"=> "WebSocket"
           )
  ,body= ""
), Message(name= "line folding in header value"
  ,raw= "GET / HTTP/1.1\n" *
         "Line1:   abc\n" *
         "\tdef\n" *
         " ghi\n" *
         "\t\tjkl\n" *
         "  mno \n" *
         "\t \tqrs\n" *
         "Line2: \t line2\t\n" *
         "Line3:\n" *
         " line3\n" *
         "Line4: \n" *
         " \n" *
         "Connection:\n" *
         " close\n" *
         "\n"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 1
  ,method= HTTP.GET
  ,query_string= ""
  ,fragment= ""
  ,request_path= "/"
  ,request_url= "/"
  ,num_headers= 5
  ,headers=Dict{String,String}( "Line1"=> "abc\tdef ghi\t\tjkl  mno \t \tqrs"
             , "Line2"=> "line2\t"
             , "Line3"=> "line3"
             , "Line4"=> ""
             , "Connection"=> "close"
           )
  ,body= ""
)
]

@testset "HTTP.parse(HTTP.Request, str)" begin
    for req in requests
        println("TESTING: $(req.name)")
        r = HTTP.parse(HTTP.Request, req.raw)
        @test HTTP.major(r) == req.http_major
        @test HTTP.minor(r) == req.http_minor
        @test HTTP.method(r) == req.method
        @test HTTP.query(HTTP.uri(r)) == req.query_string
        @test HTTP.fragment(HTTP.uri(r)) == req.fragment
        @test HTTP.path(HTTP.uri(r)) == req.request_path
        @test HTTP.hostname(HTTP.uri(r)) == req.host
        @test HTTP.userinfo(HTTP.uri(r)) == req.userinfo
        @test HTTP.port(HTTP.uri(r)) in (req.port, "80", "443")
        @test string(HTTP.uri(r)) == req.request_url
        @test length(HTTP.headers(r)) == req.num_headers
        @test HTTP.headers(r) == req.headers
        @test String(readavailable(HTTP.body(r))) == req.body
        @test HTTP.http_should_keep_alive(HTTP.DEFAULT_PARSER, r) == req.should_keep_alive
    end
end

#= * R E S P O N S E S * =#
const responses = Message[
    Message(name= "google 301"
  ,raw= "HTTP/1.1 301 Moved Permanently\r\n" *
         "Location: http://www.google.com/\r\n" *
         "Content-Type: text/html; charset=UTF-8\r\n" *
         "Date: Sun, 26 Apr 2009 11:11:49 GMT\r\n" *
         "Expires: Tue, 26 May 2009 11:11:49 GMT\r\n" *
         "X-\$PrototypeBI-Version: 1.6.0.3\r\n" * #= $ char in header field =#
         "Cache-Control: public, max-age=2592000\r\n" *
         "Server: gws\r\n" *
         "Content-Length:  219  \r\n" *
         "\r\n" *
         "<HTML><HEAD><meta http-equiv=\"content-type\" content=\"text/html;charset=utf-8\">\n" *
         "<TITLE>301 Moved</TITLE></HEAD><BODY>\n" *
         "<H1>301 Moved</H1>\n" *
         "The document has moved\n" *
         "<A HREF=\"http://www.google.com/\">here</A>.\r\n" *
         "</BODY></HTML>\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 301
  ,response_status= "Moved Permanently"
  ,num_headers= 8
  ,headers=Dict{String,String}(
      "Location"=> "http://www.google.com/"
    , "Content-Type"=> "text/html; charset=UTF-8"
    , "Date"=> "Sun, 26 Apr 2009 11:11:49 GMT"
    , "Expires"=> "Tue, 26 May 2009 11:11:49 GMT"
    , "X-\$PrototypeBI-Version"=> "1.6.0.3"
    , "Cache-Control"=> "public, max-age=2592000"
    , "Server"=> "gws"
    , "Content-Length"=> "219  "
  )
  ,body= "<HTML><HEAD><meta http-equiv=\"content-type\" content=\"text/html;charset=utf-8\">\n" *
          "<TITLE>301 Moved</TITLE></HEAD><BODY>\n" *
          "<H1>301 Moved</H1>\n" *
          "The document has moved\n" *
          "<A HREF=\"http://www.google.com/\">here</A>.\r\n" *
          "</BODY></HTML>\r\n"
), Message(name= "no content-length response"
  ,raw= "HTTP/1.1 200 OK\r\n" *
         "Date: Tue, 04 Aug 2009 07:59:32 GMT\r\n" *
         "Server: Apache\r\n" *
         "X-Powered-By: Servlet/2.5 JSP/2.1\r\n" *
         "Content-Type: text/xml; charset=utf-8\r\n" *
         "Connection: close\r\n" *
         "\r\n" *
         "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" *
         "<SOAP-ENV:Envelope xmlns:SOAP-ENV=\"http://schemas.xmlsoap.org/soap/envelope/\">\n" *
         "  <SOAP-ENV:Body>\n" *
         "    <SOAP-ENV:Fault>\n" *
         "       <faultcode>SOAP-ENV:Client</faultcode>\n" *
         "       <faultstring>Client Error</faultstring>\n" *
         "    </SOAP-ENV:Fault>\n" *
         "  </SOAP-ENV:Body>\n" *
         "</SOAP-ENV:Envelope>"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 200
  ,response_status= "OK"
  ,num_headers= 5
  ,headers=Dict{String,String}(
      "Date"=> "Tue, 04 Aug 2009 07:59:32 GMT"
    , "Server"=> "Apache"
    , "X-Powered-By"=> "Servlet/2.5 JSP/2.1"
    , "Content-Type"=> "text/xml; charset=utf-8"
    , "Connection"=> "close"
  )
  ,body= "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" *
          "<SOAP-ENV:Envelope xmlns:SOAP-ENV=\"http://schemas.xmlsoap.org/soap/envelope/\">\n" *
          "  <SOAP-ENV:Body>\n" *
          "    <SOAP-ENV:Fault>\n" *
          "       <faultcode>SOAP-ENV:Client</faultcode>\n" *
          "       <faultstring>Client Error</faultstring>\n" *
          "    </SOAP-ENV:Fault>\n" *
          "  </SOAP-ENV:Body>\n" *
          "</SOAP-ENV:Envelope>"
), Message(name= "404 no headers no body"
  ,raw= "HTTP/1.1 404 Not Found\r\n\r\n"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 404
  ,response_status= "Not Found"
  ,num_headers= 0
  ,headers=Dict{String,String}()
  ,body_size= 0
  ,body= ""
), Message(name= "301 no response phrase"
  ,raw= "HTTP/1.1 301\r\n\r\n"
  ,should_keep_alive = false
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 301
  ,response_status= ""
  ,num_headers= 0
  ,headers=Dict{String,String}()
  ,body= ""
), Message(name="200 trailing space on chunked body"
  ,raw= "HTTP/1.1 200 OK\r\n" *
         "Content-Type: text/plain\r\n" *
         "Transfer-Encoding: chunked\r\n" *
         "\r\n" *
         "25  \r\n" *
         "This is the data in the first chunk\r\n" *
         "\r\n" *
         "1C\r\n" *
         "and this is the second one\r\n" *
         "\r\n" *
         "0  \r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 200
  ,response_status= "OK"
  ,num_headers= 2
  ,headers=Dict{String,String}(
      "Content-Type"=> "text/plain"
    , "Transfer-Encoding"=> "chunked"
  )
  ,body_size = 37+28
  ,body =
         "This is the data in the first chunk\r\n" *
         "and this is the second one\r\n"
), Message(name="no carriage ret"
  ,raw= "HTTP/1.1 200 OK\n" *
         "Content-Type: text/html; charset=utf-8\n" *
         "Connection: close\n" *
         "\n" *
         "these headers are from http://news.ycombinator.com/"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 200
  ,response_status= "OK"
  ,num_headers= 2
  ,headers=Dict{String,String}(
      "Content-Type"=> "text/html; charset=utf-8"
    , "Connection"=> "close"
  )
  ,body= "these headers are from http://news.ycombinator.com/"
), Message(name="proxy connection"
  ,raw= "HTTP/1.1 200 OK\r\n" *
         "Content-Type: text/html; charset=UTF-8\r\n" *
         "Content-Length: 11\r\n" *
         "Proxy-Connection: close\r\n" *
         "Date: Thu, 31 Dec 2009 20:55:48 +0000\r\n" *
         "\r\n" *
         "hello world"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 200
  ,response_status= "OK"
  ,num_headers= 4
  ,headers=Dict{String,String}(
      "Content-Type"=> "text/html; charset=UTF-8"
    , "Content-Length"=> "11"
    , "Proxy-Connection"=> "close"
    , "Date"=> "Thu, 31 Dec 2009 20:55:48 +0000"
  )
  ,body= "hello world"
), Message(name="underscore header key"
  ,raw= "HTTP/1.1 200 OK\r\n" *
         "Server: DCLK-AdSvr\r\n" *
         "Content-Type: text/xml\r\n" *
         "Content-Length: 0\r\n" *
         "DCLK_imp: v7;x;114750856;0-0;0;17820020;0/0;21603567/21621457/1;;~okv=;dcmt=text/xml;;~cs=o\r\n\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 200
  ,response_status= "OK"
  ,num_headers= 4
  ,headers=Dict{String,String}(
      "Server"=> "DCLK-AdSvr"
    , "Content-Type"=> "text/xml"
    , "Content-Length"=> "0"
    , "DCLK_imp"=> "v7;x;114750856;0-0;0;17820020;0/0;21603567/21621457/1;;~okv=;dcmt=text/xml;;~cs=o"
  )
  ,body= ""
), Message(name= "bonjourmadame.fr"
  ,raw= "HTTP/1.0 301 Moved Permanently\r\n" *
         "Date: Thu, 03 Jun 2010 09:56:32 GMT\r\n" *
         "Server: Apache/2.2.3 (Red Hat)\r\n" *
         "Cache-Control: public\r\n" *
         "Pragma: \r\n" *
         "Location: http://www.bonjourmadame.fr/\r\n" *
         "Vary: Accept-Encoding\r\n" *
         "Content-Length: 0\r\n" *
         "Content-Type: text/html; charset=UTF-8\r\n" *
         "Connection: keep-alive\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 0
  ,status_code= 301
  ,response_status= "Moved Permanently"
  ,num_headers= 9
  ,headers=Dict{String,String}(
      "Date"=> "Thu, 03 Jun 2010 09:56:32 GMT"
    , "Server"=> "Apache/2.2.3 (Red Hat)"
    , "Cache-Control"=> "public"
    , "Pragma"=> ""
    , "Location"=> "http://www.bonjourmadame.fr/"
    , "Vary"=>  "Accept-Encoding"
    , "Content-Length"=> "0"
    , "Content-Type"=> "text/html; charset=UTF-8"
    , "Connection"=> "keep-alive"
  )
  ,body= ""
), Message(name= "field underscore"
  ,raw= "HTTP/1.1 200 OK\r\n" *
         "Date: Tue, 28 Sep 2010 01:14:13 GMT\r\n" *
         "Server: Apache\r\n" *
         "Cache-Control: no-cache, must-revalidate\r\n" *
         "Expires: Mon, 26 Jul 1997 05:00:00 GMT\r\n" *
         ".et-Cookie: PlaxoCS=1274804622353690521; path=/; domain=.plaxo.com\r\n" *
         "Vary: Accept-Encoding\r\n" *
         "_eep-Alive: timeout=45\r\n" * #= semantic value ignored =#
         "_onnection: Keep-Alive\r\n" * #= semantic value ignored =#
         "Transfer-Encoding: chunked\r\n" *
         "Content-Type: text/html\r\n" *
         "Connection: close\r\n" *
         "\r\n" *
         "0\r\n\r\n"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 200
  ,response_status= "OK"
  ,num_headers= 11
  ,headers=Dict{String,String}(
      "Date"=> "Tue, 28 Sep 2010 01:14:13 GMT"
    , "Server"=> "Apache"
    , "Cache-Control"=> "no-cache, must-revalidate"
    , "Expires"=> "Mon, 26 Jul 1997 05:00:00 GMT"
    , ".et-Cookie"=> "PlaxoCS=1274804622353690521; path=/; domain=.plaxo.com"
    , "Vary"=> "Accept-Encoding"
    , "_eep-Alive"=> "timeout=45"
    , "_onnection"=> "Keep-Alive"
    , "Transfer-Encoding"=> "chunked"
    , "Content-Type"=> "text/html"
    , "Connection"=> "close"
  )
  ,body= ""
), Message(name= "non-ASCII in status line"
  ,raw= "HTTP/1.1 500 Oriëntatieprobleem\r\n" *
         "Date: Fri, 5 Nov 2010 23:07:12 GMT+2\r\n" *
         "Content-Length: 0\r\n" *
         "Connection: close\r\n" *
         "\r\n"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 500
  ,response_status= "Oriëntatieprobleem"
  ,num_headers= 3
  ,headers=Dict{String,String}(
      "Date"=> "Fri, 5 Nov 2010 23:07:12 GMT+2"
    , "Content-Length"=> "0"
    , "Connection"=> "close"
  )
  ,body= ""
), Message(name= "http version 0.9"
  ,raw= "HTTP/0.9 200 OK\r\n" *
         "\r\n"
  ,should_keep_alive= false
  ,http_major= 0
  ,http_minor= 9
  ,status_code= 200
  ,response_status= "OK"
  ,num_headers= 0
  ,headers=Dict{String,String}()
  ,body= ""
), Message(name= "neither content-length nor transfer-encoding response"
  ,raw= "HTTP/1.1 200 OK\r\n" *
         "Content-Type: text/plain\r\n" *
         "\r\n" *
         "hello world"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 200
  ,response_status= "OK"
  ,num_headers= 1
  ,headers=Dict{String,String}(
      "Content-Type"=> "text/plain"
  )
  ,body= "hello world"
), Message(name= "HTTP/1.0 with keep-alive and EOF-terminated 200 status"
  ,raw= "HTTP/1.0 200 OK\r\n" *
         "Connection: keep-alive\r\n" *
         "\r\n"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 0
  ,status_code= 200
  ,response_status= "OK"
  ,num_headers= 1
  ,headers=Dict{String,String}(
      "Connection"=> "keep-alive"
  )
  ,body_size= 0
  ,body= ""
), Message(name= "HTTP/1.0 with keep-alive and a 204 status"
  ,raw= "HTTP/1.0 204 No content\r\n" *
         "Connection: keep-alive\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 0
  ,status_code= 204
  ,response_status= "No content"
  ,num_headers= 1
  ,headers=Dict{String,String}(
      "Connection"=> "keep-alive"
  )
  ,body_size= 0
  ,body= ""
), Message(name= "HTTP/1.1 with an EOF-terminated 200 status"
  ,raw= "HTTP/1.1 200 OK\r\n" *
         "\r\n"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 200
  ,response_status= "OK"
  ,num_headers= 0
  ,headers=Dict{String,String}()
  ,body_size= 0
  ,body= ""
), Message(name= "HTTP/1.1 with a 204 status"
  ,raw= "HTTP/1.1 204 No content\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 204
  ,response_status= "No content"
  ,num_headers= 0
  ,headers=Dict{String,String}()
  ,body_size= 0
  ,body= ""
), Message(name= "HTTP/1.1 with a 204 status and keep-alive disabled"
  ,raw= "HTTP/1.1 204 No content\r\n" *
         "Connection: close\r\n" *
         "\r\n"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 204
  ,response_status= "No content"
  ,num_headers= 1
  ,headers=Dict{String,String}(
      "Connection"=> "close"
  )
  ,body_size= 0
  ,body= ""
), Message(name= "HTTP/1.1 with chunked endocing and a 200 response"
  ,raw= "HTTP/1.1 200 OK\r\n" *
         "Transfer-Encoding: chunked\r\n" *
         "\r\n" *
         "0\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 200
  ,response_status= "OK"
  ,num_headers= 1
  ,headers=Dict{String,String}(
      "Transfer-Encoding"=> "chunked"
  )
  ,body_size= 0
  ,body= ""
), Message(name= "field space"
  ,raw= "HTTP/1.1 200 OK\r\n" *
         "Server: Microsoft-IIS/6.0\r\n" *
         "X-Powered-By: ASP.NET\r\n" *
         "en-US Content-Type: text/xml\r\n" * #= this is the problem =#
         "Content-Type: text/xml\r\n" *
         "Content-Length: 16\r\n" *
         "Date: Fri, 23 Jul 2010 18:45:38 GMT\r\n" *
         "Connection: keep-alive\r\n" *
         "\r\n" *
         "<xml>hello</xml>" #= fake body =#
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 200
  ,response_status= "OK"
  ,num_headers= 7
  ,headers=Dict{String,String}(
      "Server"=>  "Microsoft-IIS/6.0"
    , "X-Powered-By"=> "ASP.NET"
    , "en-US Content-Type"=> "text/xml"
    , "Content-Type"=> "text/xml"
    , "Content-Length"=> "16"
    , "Date"=> "Fri, 23 Jul 2010 18:45:38 GMT"
    , "Connection"=> "keep-alive"
  )
  ,body= "<xml>hello</xml>"
), Message(name= "amazon.com"
  ,raw= "HTTP/1.1 301 MovedPermanently\r\n" *
         "Date: Wed, 15 May 2013 17:06:33 GMT\r\n" *
         "Server: Server\r\n" *
         "x-amz-id-1: 0GPHKXSJQ826RK7GZEB2\r\n" *
         "p3p: policyref=\"http://www.amazon.com/w3c/p3p.xml\",CP=\"CAO DSP LAW CUR ADM IVAo IVDo CONo OTPo OUR DELi PUBi OTRi BUS PHY ONL UNI PUR FIN COM NAV INT DEM CNT STA HEA PRE LOC GOV OTC \"\r\n" *
         "x-amz-id-2: STN69VZxIFSz9YJLbz1GDbxpbjG6Qjmmq5E3DxRhOUw+Et0p4hr7c/Q8qNcx4oAD\r\n" *
         "Location: http://www.amazon.com/Dan-Brown/e/B000AP9DSU/ref=s9_pop_gw_al1?_encoding=UTF8&refinementId=618073011&pf_rd_m=ATVPDKIKX0DER&pf_rd_s=center-2&pf_rd_r=0SHYY5BZXN3KR20BNFAY&pf_rd_t=101&pf_rd_p=1263340922&pf_rd_i=507846\r\n" *
         "Vary: Accept-Encoding,User-Agent\r\n" *
         "Content-Type: text/html; charset=ISO-8859-1\r\n" *
         "Transfer-Encoding: chunked\r\n" *
         "\r\n" *
         "1\r\n" *
         "\n\r\n" *
         "0\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 301
  ,response_status= "MovedPermanently"
  ,num_headers= 9
  ,headers=Dict{String,String}( "Date"=> "Wed, 15 May 2013 17:06:33 GMT"
             , "Server"=> "Server"
             , "x-amz-id-1"=> "0GPHKXSJQ826RK7GZEB2"
             , "p3p"=> "policyref=\"http://www.amazon.com/w3c/p3p.xml\"=>CP=\"CAO DSP LAW CUR ADM IVAo IVDo CONo OTPo OUR DELi PUBi OTRi BUS PHY ONL UNI PUR FIN COM NAV INT DEM CNT STA HEA PRE LOC GOV OTC \""
             , "x-amz-id-2"=> "STN69VZxIFSz9YJLbz1GDbxpbjG6Qjmmq5E3DxRhOUw+Et0p4hr7c/Q8qNcx4oAD"
             , "Location"=> "http://www.amazon.com/Dan-Brown/e/B000AP9DSU/ref=s9_pop_gw_al1?_encoding=UTF8&refinementId=618073011&pf_rd_m=ATVPDKIKX0DER&pf_rd_s=center-2&pf_rd_r=0SHYY5BZXN3KR20BNFAY&pf_rd_t=101&pf_rd_p=1263340922&pf_rd_i=507846"
             , "Vary"=> "Accept-Encoding,User-Agent"
             , "Content-Type"=> "text/html; charset=ISO-8859-1"
             , "Transfer-Encoding"=> "chunked"
           )
  ,body= "\n"
), Message(name= "empty reason phrase after space"
  ,raw= "HTTP/1.1 200 \r\n" *
         "\r\n"
  ,should_keep_alive= false
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 200
  ,response_status= ""
  ,num_headers= 0
  ,headers=Dict{String,String}()
  ,body= ""
), Message(name= "Content-Length-X"
  ,raw= "HTTP/1.1 200 OK\r\n" *
         "Content-Length-X: 0\r\n" *
         "Transfer-Encoding: chunked\r\n" *
         "\r\n" *
         "2\r\n" *
         "OK\r\n" *
         "0\r\n" *
         "\r\n"
  ,should_keep_alive= true
  ,http_major= 1
  ,http_minor= 1
  ,status_code= 200
  ,response_status= "OK"
  ,num_headers= 2
  ,headers=Dict{String,String}( "Content-Length-X"=> "0"
             , "Transfer-Encoding"=> "chunked"
           )
  ,body= "OK"
), Message() #= sentinel =#
]


int
message_eq (int index, int connect, const struct message *expected)
{
  int i;
  struct message *m = &messages[index];

  MESSAGE_CHECK_NUM_EQ(expected, m, http_major);
  MESSAGE_CHECK_NUM_EQ(expected, m, http_minor);

  if (expected.type == HTTP.REQUEST) {
    MESSAGE_CHECK_NUM_EQ(expected, m, method);
  } else {
    MESSAGE_CHECK_NUM_EQ(expected, m, status_code);
    MESSAGE_CHECK_STR_EQ(expected, m, response_status);
  }

  if (!connect) {
    MESSAGE_CHECK_NUM_EQ(expected, m, should_keep_alive);
    MESSAGE_CHECK_NUM_EQ(expected, m, message_complete_on_eof);
  }



  MESSAGE_CHECK_STR_EQ(expected, m, request_url);

  #= Check URL components; we can't do this w/ CONNECT since it doesn't
   * send us a well-formed URL.
   =#
  if (*m.request_url && m.method != HTTP_CONNECT) {
    struct http_parser_url u;

    if (http_parser_parse_url(m.request_url, strlen(m.request_url), 0, &u)) {
      error("\n\n*** failed to parse URL %s ***\n\n",
        m.request_url);
    }

    if (expected.host) {
      MESSAGE_CHECK_URL_EQ(&u, expected, m, host, UF_HOST);
    }

    if (expected.userinfo) {
      MESSAGE_CHECK_URL_EQ(&u, expected, m, userinfo, UF_USERINFO);
    }

    m.port = (u.field_set & (1 << UF_PORT)) ?
      uport : 0;

    MESSAGE_CHECK_URL_EQ(&u, expected, m, query_string, UF_QUERY);
    MESSAGE_CHECK_URL_EQ(&u, expected, m, fragment, UF_FRAGMENT);
    MESSAGE_CHECK_URL_EQ(&u, expected, m, request_path, UF_PATH);
    MESSAGE_CHECK_NUM_EQ(expected, m, port);
  }

  if (connect) {
    check_num_eq(m, "body_size", 0, m.body_size);
  } else if (expected.body_size) {
    MESSAGE_CHECK_NUM_EQ(expected, m, body_size);
  } else {
    MESSAGE_CHECK_STR_EQ(expected, m, body);
  }

  if (connect) {
  } else {
    }
  }

  MESSAGE_CHECK_NUM_EQ(expected, m, num_headers);

  int r;
  for (i = 0; i < m.num_headers; i++) {
    r = check_str_eq(expected, "header field", expected.headers[i][0], m.headers[i][0]);
    if (!r) return 0;
    r = check_str_eq(expected, "header value", expected.headers[i][1], m.headers[i][1]);
    if (!r) return 0;
  }

  MESSAGE_CHECK_STR_EQ(expected, m, upgrade);

  return 1;
end

#= Given a sequence of varargs messages, return the number of them that the
 * parser should successfully parse, taking into account that upgraded
 * messages prevent all subsequent messages from being parsed.
 =#
size_t
count_parsed_messages(const size_t nmsgs, ...) {
  size_t i;
  va_list ap;

  va_start(ap, nmsgs);

  for (i = 0; i < nmsgs; i++) {
    struct message *m = va_arg(ap, struct message *);

    if (m.upgrade) {
      va_end(ap);
      return i + 1;
    }
  }

  va_end(ap);
  return nmsgs;
end

#= Given a sequence of bytes and the number of these that we were able to
 * parse, verify that upgrade bodies are correct.
 =#
void
upgrade_message_fix(char *body, const size_t nread, const size_t nmsgs, ...) {
  va_list ap;
  size_t i;
  size_t off = 0;

  va_start(ap, nmsgs);

  for (i = 0; i < nmsgs; i++) {
    struct message *m = va_arg(ap, struct message *);

    off += strlen(m.raw);

    if (m.upgrade) {
      off -= strlen(m.upgrade);

      #= Check the portion of the response after its specified upgrade =#
      if (!check_str_eq(m, "upgrade", body + off, body + nread)) {
      }

      #= Fix up the response so that message_eq() will verify the beginning
       * of the upgrade =#
      *(body + nread + strlen(m.upgrade)) = '\0';
      messages[num_messages -1 ]upgrade = body + nread;

      va_end(ap);
      return;
    }
  }

  va_end(ap);
  print("\n\n*** Error: expected a message with upgrade ***\n");

end

static void
print_error (const char *raw, size_t error_location)
{
  error("\n*** %s ***\n\n",
          http_errno_description(HTTP_PARSER_ERRNO(parser)));

  int this_line = 0, char_len = 0;
  size_t i, j, len = strlen(raw), error_location_line = 0;
  for (i = 0; i < len; i++) {
    if (i == error_location) this_line = 1;
    switch (raw[i]) {
      case '\r':
        char_len = 2;
        error("\\r");
        break;

      case '\n':
        error("\\n\n");

        if (this_line) goto print;

        error_location_line = 0;
        continue;

      default:
        char_len = 1;
        fputc(raw[i], stderr);
        break;
    }
    if (!this_line) error_location_line += char_len;
  }

  error("[eof]\n");

 print:
  for (j = 0; j < error_location_line; j++) {
    fputc(' ', stderr);
  }
  error("^\n\nerror location: %u\n", (unsigned int)error_location);
end

void
test_preserve_data (void)
{
  char my_data[] = "application-specific data";
  http_parser parser;
  parser.data = my_data;
  http_parser_init(&parser, HTTP.REQUEST);
  if (parser.data != my_data) {
    print("\n*** parser.data not preserved accross http_parser_init ***\n\n");
  }
end

void
test_message (const struct message *message)
{
  size_t raw_len = strlen(message.raw);
  size_t msg1len;
  for (msg1len = 0; msg1len < raw_len; msg1len++) {
    parser_init(message.type);

    size_t read;
    const char *msg1 = message.raw;
    const char *msg2 = msg1 + msg1len;
    size_t msg2len = raw_len - msg1len;

    if (msg1len) {
      read = parse(msg1, msg1len);

      if (message.upgrade && parser.upgrade && num_messages > 0) {
        messages[num_messages - 1]upgrade = msg1 + read;
        goto test;
      }

      if (read != msg1len) {
        print_error(msg1, read);
      }
    }


    read = parse(msg2, msg2len);

    if (message.upgrade && parser.upgrade) {
      messages[num_messages - 1]upgrade = msg2 + read;
      goto test;
    }

    if (read != msg2len) {
      print_error(msg2, read);
    }

    read = parse(NULL, 0);

    if (read != 0) {
      print_error(message.raw, read);
    }

  test:

    if (num_messages != 1) {
      print("\n*** num_messages != 1 after testing '%s' ***\n\n", message.name);
    }


    parser_free();
  }
end

void
test_message_count_body (const struct message *message)
{
  parser_init(message.type);

  size_t read;
  size_t l = strlen(message.raw);
  size_t i, toread;
  size_t chunk = 4024;

  for (i = 0; i < l; i+= chunk) {
    toread = min(l-i, chunk);
    read = parse_count_body(message.raw + i, toread);
    if (read != toread) {
      print_error(message.raw, read);
    }
  }


  read = parse_count_body(NULL, 0);
  if (read != 0) {
    print_error(message.raw, read);
  }

  if (num_messages != 1) {
    print("\n*** num_messages != 1 after testing '%s' ***\n\n", message.name);
  }


  parser_free();
end

void
test_simple (const char *buf, enum http_errno err_expected)
{
  parser_init(HTTP.REQUEST);

  enum http_errno err;

  parse(buf, strlen(buf));
  err = HTTP_PARSER_ERRNO(parser);
  parse(NULL, 0);

  parser_free();

  #= In strict mode, allow us to pass with an unexpected HPE_STRICT as
   * long as the caller isn't expecting success.
   =#
#if HTTP_PARSER_STRICT
  if (err_expected != err && err_expected != HPE_OK && err != HPE_STRICT) {
#else
  if (err_expected != err) {
#endif
    error("\n*** test_simple expected %s, but saw %s ***\n\n%s\n",
        http_errno_name(err_expected), http_errno_name(err), buf);
  }
end

void
test_invalid_header_content (int req, const char* str)
{
  http_parser parser;
  http_parser_init(&parser, req ? HTTP.REQUEST : HTTP.RESPONSE);
  size_t parsed;
  const char *buf;
  buf = req ?
    "GET / HTTP/1.1\r\n" :
    "HTTP/1.1 200 OK\r\n";
  parsed = http_parser_execute(&parser, &settings_null, buf, strlen(buf));
  assert(parsed == strlen(buf));

  buf = str;
  size_t buflen = strlen(buf);

  parsed = http_parser_execute(&parser, &settings_null, buf, buflen);
  if (parsed != buflen) {
    assert(HTTP_PARSER_ERRNO(&parser) == HPE_INVALID_HEADER_TOKEN);
    return;
  }

  fprint(stderr,
          "\n*** Error expected but none in invalid header content test ***\n");
end

void
test_invalid_header_field_content_error (int req)
{
  test_invalid_header_content(req, "Foo: F\01ailure");
  test_invalid_header_content(req, "Foo: B\02ar");
end

void
test_invalid_header_field (int req, const char* str)
{
  http_parser parser;
  http_parser_init(&parser, req ? HTTP.REQUEST : HTTP.RESPONSE);
  size_t parsed;
  const char *buf;
  buf = req ?
    "GET / HTTP/1.1\r\n" :
    "HTTP/1.1 200 OK\r\n";
  parsed = http_parser_execute(&parser, &settings_null, buf, strlen(buf));
  assert(parsed == strlen(buf));

  buf = str;
  size_t buflen = strlen(buf);

  parsed = http_parser_execute(&parser, &settings_null, buf, buflen);
  if (parsed != buflen) {
    assert(HTTP_PARSER_ERRNO(&parser) == HPE_INVALID_HEADER_TOKEN);
    return;
  }

  fprint(stderr,
          "\n*** Error expected but none in invalid header token test ***\n");
end

void
test_invalid_header_field_token_error (int req)
{
  test_invalid_header_field(req, "Fo@: Failure");
  test_invalid_header_field(req, "Foo\01\test: Bar");
end

void
test_double_content_length_error (int req)
{
  http_parser parser;
  http_parser_init(&parser, req ? HTTP.REQUEST : HTTP.RESPONSE);
  size_t parsed;
  const char *buf;
  buf = req ?
    "GET / HTTP/1.1\r\n" :
    "HTTP/1.1 200 OK\r\n";
  parsed = http_parser_execute(&parser, &settings_null, buf, strlen(buf));
  assert(parsed == strlen(buf));

  buf = "Content-Length: 0\r\nContent-Length: 1\r\n\r\n";
  size_t buflen = strlen(buf);

  parsed = http_parser_execute(&parser, &settings_null, buf, buflen);
  if (parsed != buflen) {
    assert(HTTP_PARSER_ERRNO(&parser) == HPE_UNEXPECTED_CONTENT_LENGTH);
    return;
  }

  fprint(stderr,
          "\n*** Error expected but none in double content-length test ***\n");
end

void
test_chunked_content_length_error (int req)
{
  http_parser parser;
  http_parser_init(&parser, req ? HTTP.REQUEST : HTTP.RESPONSE);
  size_t parsed;
  const char *buf;
  buf = req ?
    "GET / HTTP/1.1\r\n" :
    "HTTP/1.1 200 OK\r\n";
  parsed = http_parser_execute(&parser, &settings_null, buf, strlen(buf));
  assert(parsed == strlen(buf));

  buf = "Transfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n";
  size_t buflen = strlen(buf);

  parsed = http_parser_execute(&parser, &settings_null, buf, buflen);
  if (parsed != buflen) {
    assert(HTTP_PARSER_ERRNO(&parser) == HPE_UNEXPECTED_CONTENT_LENGTH);
    return;
  }

  fprint(stderr,
          "\n*** Error expected but none in chunked content-length test ***\n");
end

void
test_header_cr_no_lf_error (int req)
{
  http_parser parser;
  http_parser_init(&parser, req ? HTTP.REQUEST : HTTP.RESPONSE);
  size_t parsed;
  const char *buf;
  buf = req ?
    "GET / HTTP/1.1\r\n" :
    "HTTP/1.1 200 OK\r\n";
  parsed = http_parser_execute(&parser, &settings_null, buf, strlen(buf));
  assert(parsed == strlen(buf));

  buf = "Foo: 1\rBar: 1\r\n\r\n";
  size_t buflen = strlen(buf);

  parsed = http_parser_execute(&parser, &settings_null, buf, buflen);
  if (parsed != buflen) {
    assert(HTTP_PARSER_ERRNO(&parser) == HPE_LF_EXPECTED);
    return;
  }

  fprint(stderr,
          "\n*** Error expected but none in header whitespace test ***\n");
end

void
test_header_overflow_error (int req)
{
  http_parser parser;
  http_parser_init(&parser, req ? HTTP.REQUEST : HTTP.RESPONSE);
  size_t parsed;
  const char *buf;
  buf = req ? "GET / HTTP/1.1\r\n" : "HTTP/1.0 200 OK\r\n";
  parsed = http_parser_execute(&parser, &settings_null, buf, strlen(buf));
  assert(parsed == strlen(buf));

  buf = "header-key: header-value\r\n";
  size_t buflen = strlen(buf);

  int i;
  for (i = 0; i < 10000; i++) {
    parsed = http_parser_execute(&parser, &settings_null, buf, buflen);
    if (parsed != buflen) {
      #error("error found on iter %d\n", i);
      assert(HTTP_PARSER_ERRNO(&parser) == HPE_HEADER_OVERFLOW);
      return;
    }
  }

  error("\n*** Error expected but none in header overflow test ***\n");
end


void
test_header_nread_value ()
{
  http_parser parser;
  http_parser_init(&parser, HTTP.REQUEST);
  size_t parsed;
  const char *buf;
  buf = "GET / HTTP/1.1\r\nheader: value\nhdr: value\r\n";
  parsed = http_parser_execute(&parser, &settings_null, buf, strlen(buf));
  assert(parsed == strlen(buf));

  assert(parser.nread == strlen(buf));
end


static void
test_content_length_overflow (const char *buf, size_t buflen, int expect_ok)
{
  http_parser parser;
  http_parser_init(&parser, HTTP.RESPONSE);
  http_parser_execute(&parser, &settings_null, buf, buflen);

  if (expect_ok)
    assert(HTTP_PARSER_ERRNO(&parser) == HPE_OK);
  else
    assert(HTTP_PARSER_ERRNO(&parser) == HPE_INVALID_CONTENT_LENGTH);
end

void
test_header_content_length_overflow_error (void)
{
#define X(size)                                                               \
  "HTTP/1.1 200 OK\r\n"                                                       \
  "Content-Length: " #size "\r\n"                                             \
  "\r\n"
  const char a[] = X(1844674407370955160);  #= 2^64 / 10 - 1 =#
  const char b[] = X(18446744073709551615); #= 2^64-1 =#
  const char c[] = X(18446744073709551616); #= 2^64   =#
#undef X
  test_content_length_overflow(a, sizeof(a) - 1, 1); #= expect ok      =#
  test_content_length_overflow(b, sizeof(b) - 1, 0); #= expect failure =#
  test_content_length_overflow(c, sizeof(c) - 1, 0); #= expect failure =#
end

void
test_chunk_content_length_overflow_error (void)
{
#define X(size)                                                               \
    "HTTP/1.1 200 OK\r\n"                                                     \
    "Transfer-Encoding: chunked\r\n"                                          \
    "\r\n"                                                                    \
    #size "\r\n"                                                              \
    "..."
  const char a[] = X(FFFFFFFFFFFFFFE);   #= 2^64 / 16 - 1 =#
  const char b[] = X(FFFFFFFFFFFFFFFF);  #= 2^64-1 =#
  const char c[] = X(10000000000000000); #= 2^64   =#
#undef X
  test_content_length_overflow(a, sizeof(a) - 1, 1); #= expect ok      =#
  test_content_length_overflow(b, sizeof(b) - 1, 0); #= expect failure =#
  test_content_length_overflow(c, sizeof(c) - 1, 0); #= expect failure =#
end

void
test_no_overflow_long_body (int req, size_t length)
{
  http_parser parser;
  http_parser_init(&parser, req ? HTTP.REQUEST : HTTP.RESPONSE);
  size_t parsed;
  size_t i;
  char buf1[3000];
  size_t buf1len = sprint(buf1, "%s\r\nConnection: Keep-Alive\r\nContent-Length: %lu\r\n\r\n",
      req ? "POST / HTTP/1.0" : "HTTP/1.0 200 OK", (unsigned long)length);
  parsed = http_parser_execute(&parser, &settings_null, buf1, buf1len);
  if (parsed != buf1len)
    goto err;

  for (i = 0; i < length; i++) {
    char foo = 'a';
    parsed = http_parser_execute(&parser, &settings_null, &foo, 1);
    if (parsed != 1)
      goto err;
  }

  parsed = http_parser_execute(&parser, &settings_null, buf1, buf1len);
  if (parsed != buf1len) goto err;
  return;

 err:
  fprint(stderr,
          "\n*** error in test_no_overflow_long_body %s of length %lu ***\n",
          req ? "REQUEST" : "RESPONSE",
          (unsigned long)length);
end

void
test_multiple3 (const struct message *r1, const struct message *r2, const struct message *r3)
{
  int message_count = count_parsed_messages(3, r1, r2, r3);

  char total[ strlen(r1.raw)
            + strlen(r2.raw)
            + strlen(r3.raw)
            + 1
            ];
  total[0] = '\0';

  strcat(total, r1.raw);
  strcat(total, r2.raw);
  strcat(total, r3.raw);

  parser_init(r1.type);

  size_t read;

  read = parse(total, strlen(total));

  if (parser.upgrade) {
    upgrade_message_fix(total, read, 3, r1, r2, r3);
    goto test;
  }

  if (read != strlen(total)) {
    print_error(total, read);
  }

  read = parse(NULL, 0);

  if (read != 0) {
    print_error(total, read);
  }

test:

  if (message_count != num_messages) {
    error("\n\n*** Parser didn't see 3 messages only %d *** \n", num_messages);
  }


  parser_free();
end

#= SCAN through every possible breaking to make sure the
 * parser can handle getting the content in any chunks that
 * might come from the socket
 =#
void
test_scan (const struct message *r1, const struct message *r2, const struct message *r3)
{
  char total[80*1024] = "\0";
  char buf1[80*1024] = "\0";
  char buf2[80*1024] = "\0";
  char buf3[80*1024] = "\0";

  strcat(total, r1.raw);
  strcat(total, r2.raw);
  strcat(total, r3.raw);

  size_t read;

  int total_len = strlen(total);

  int total_ops = 2 * (total_len - 1) * (total_len - 2) / 2;
  int ops = 0 ;

  size_t buf1_len, buf2_len, buf3_len;
  int message_count = count_parsed_messages(3, r1, r2, r3);

  int i,j,type_both;
  for (type_both = 0; type_both < 2; type_both ++ ) {
    for (j = 2; j < total_len; j ++ ) {
      for (i = 1; i < j; i ++ ) {

        if (ops % 1000 == 0)  {
          print("\b\b\b\b%3.0f%%", 100 * (float)ops /(float)total_ops);
          fflush(stdout);
        }
        ops += 1;

        parser_init(type_both ? HTTP_BOTH : r1.type);

        buf1_len = i;
        strlncpy(buf1, sizeof(buf1), total, buf1_len);
        buf1[buf1_len] = 0;

        buf2_len = j - i;
        strlncpy(buf2, sizeof(buf1), total+i, buf2_len);
        buf2[buf2_len] = 0;

        buf3_len = total_len - j;
        strlncpy(buf3, sizeof(buf1), total+j, buf3_len);
        buf3[buf3_len] = 0;

        read = parse(buf1, buf1_len);

        if (parser.upgrade) goto test;

        if (read != buf1_len) {
          print_error(buf1, read);
          goto error;
        }

        read += parse(buf2, buf2_len);

        if (parser.upgrade) goto test;

        if (read != buf1_len + buf2_len) {
          print_error(buf2, read);
          goto error;
        }

        read += parse(buf3, buf3_len);

        if (parser.upgrade) goto test;

        if (read != buf1_len + buf2_len + buf3_len) {
          print_error(buf3, read);
          goto error;
        }

        parse(NULL, 0);

test:
        if (parser.upgrade) {
          upgrade_message_fix(total, read, 3, r1, r2, r3);
        }

        if (message_count != num_messages) {
          error("\n\nParser didn't see %d messages only %d\n",
            message_count, num_messages);
          goto error;
        }

        if (!message_eq(0, 0, r1)) {
          error("\n\nError matching messages[0] in test_scan.\n");
          goto error;
        }

        if (message_count > 1 && !message_eq(1, 0, r2)) {
          error("\n\nError matching messages[1] in test_scan.\n");
          goto error;
        }

        if (message_count > 2 && !message_eq(2, 0, r3)) {
          error("\n\nError matching messages[2] in test_scan.\n");
          goto error;
        }

        parser_free();
      }
    }
  }
  puts("\b\b\b\b100%");
  return;

 error:
  error("i=%d  j=%d\n", i, j);
  error("buf1 (%u) %s\n\n", (unsigned int)buf1_len, buf1);
  error("buf2 (%u) %s\n\n", (unsigned int)buf2_len , buf2);
  error("buf3 (%u) %s\n", (unsigned int)buf3_len, buf3);
end

# user required to free the result
# string terminated by \0
char *
create_large_chunked_message (int body_size_in_kb, const char* headers)
{
  int i;
  size_t wrote = 0;
  size_t headers_len = strlen(headers);
  size_t bufsize = headers_len + (5+1024+2)*body_size_in_kb + 6;
  char * buf = malloc(bufsize);

  memcpy(buf, headers, headers_len);
  wrote += headers_len;

  for (i = 0; i < body_size_in_kb; i++) {
    # write 1kb chunk into the body.
    memcpy(buf + wrote, "400\r\n", 5);
    wrote += 5;
    memset(buf + wrote, 'C', 1024);
    wrote += 1024;
    strcpy(buf + wrote, "\r\n");
    wrote += 2;
  }

  memcpy(buf + wrote, "0\r\n\r\n", 6);
  wrote += 6;
  assert(wrote == bufsize);

  return buf;
end

#= Verify that we can pause parsing at any of the bytes in the
 * message and still get the result that we're expecting. =#
void
test_message_pause (const struct message *msg)
{
  char *buf = (char*) msg.raw;
  size_t buflen = strlen(msg.raw);
  size_t nread;

  parser_init(msg.type);

  do {
    nread = parse_pause(buf, buflen);

    # We can only set the upgrade buffer once we've gotten our message
    # completion callback.
        msg.upgrade &&
        parser.upgrade) {
      messages[0]upgrade = buf + nread;
      goto test;
    }

    if (nread < buflen) {

      # Not much do to if we failed a strict-mode check
      if (HTTP_PARSER_ERRNO(parser) == HPE_STRICT) {
        parser_free();
        return;
      }

      assert (HTTP_PARSER_ERRNO(parser) == HPE_PAUSED);
    }

    buf += nread;
    buflen -= nread;
    http_parser_pause(parser, 0);
  } while (buflen > 0);

  nread = parse_pause(NULL, 0);
  assert (nread == 0);

test:
  if (num_messages != 1) {
    print("\n*** num_messages != 1 after testing '%s' ***\n\n", msg.name);
  }


  parser_free();
end

#= Verify that body and next message won't be parsed in responses to CONNECT =#
void
test_message_connect (const struct message *msg)
{
  char *buf = (char*) msg.raw;
  size_t buflen = strlen(msg.raw);

  parser_init(msg.type);

  parse_connect(buf, buflen);

  if (num_messages != 1) {
    print("\n*** num_messages != 1 after testing '%s' ***\n\n", msg.name);
  }


  parser_free();
end

int
main (void)
{
  parser = NULL;
  int i, j, k;
  int request_count;
  int response_count;
  unsigned long version;
  unsigned major;
  unsigned minor;
  unsigned patch;

  version = http_parser_version();
  major = (version >> 16) & 255;
  minor = (version >> 8) & 255;
  patch = version & 255;
  print("http_parser v%u.%u.%u (0x%06lx)\n", major, minor, patch, version);

  print("sizeof(http_parser) = %u\n", (unsigned int)sizeof(http_parser));

  for (request_count = 0; requests[request_count].name; request_count++);
  for (response_count = 0; responses[response_count].name; response_count++);

  ## API
  test_preserve_data();
  test_parse_url();
  test_method_str();

  ## NREAD
  test_header_nread_value();

  ## OVERFLOW CONDITIONS

  test_header_overflow_error(HTTP.REQUEST);
  test_no_overflow_long_body(HTTP.REQUEST, 1000);
  test_no_overflow_long_body(HTTP.REQUEST, 100000);

  test_header_overflow_error(HTTP.RESPONSE);
  test_no_overflow_long_body(HTTP.RESPONSE, 1000);
  test_no_overflow_long_body(HTTP.RESPONSE, 100000);

  test_header_content_length_overflow_error();
  test_chunk_content_length_overflow_error();

  ## HEADER FIELD CONDITIONS
  test_double_content_length_error(HTTP.REQUEST);
  test_chunked_content_length_error(HTTP.REQUEST);
  test_header_cr_no_lf_error(HTTP.REQUEST);
  test_invalid_header_field_token_error(HTTP.REQUEST);
  test_invalid_header_field_content_error(HTTP.REQUEST);
  test_double_content_length_error(HTTP.RESPONSE);
  test_chunked_content_length_error(HTTP.RESPONSE);
  test_header_cr_no_lf_error(HTTP.RESPONSE);
  test_invalid_header_field_token_error(HTTP.RESPONSE);
  test_invalid_header_field_content_error(HTTP.RESPONSE);

  ## RESPONSES

  for (i = 0; i < response_count; i++) {
    test_message(&responses[i]);
  }

  for (i = 0; i < response_count; i++) {
    test_message_pause(&responses[i]);
  }

  for (i = 0; i < response_count; i++) {
    test_message_connect(&responses[i]);
  }

  for (i = 0; i < response_count; i++) {
    if (!responses[i]should_keep_alive) continue;
    for (j = 0; j < response_count; j++) {
      if (!responses[j]should_keep_alive) continue;
      for (k = 0; k < response_count; k++) {
        test_multiple3(&responses[i], &responses[j], &responses[k]);
      }
    }
  }

  test_message_count_body(&responses[NO_HEADERS_NO_BODY_404]);
  test_message_count_body(&responses[TRAILING_SPACE_ON_CHUNKED_BODY]);

  # test very large chunked response
  {
    char * msg = create_large_chunked_message(31337,
      "HTTP/1.0 200 OK\r\n"
      "Transfer-Encoding: chunked\r\n"
      "Content-Type: text/plain\r\n"
      "\r\n");
    struct message large_chunked =
      Message(name= "large chunked"
      ,raw= msg
      ,should_keep_alive= false
      ,http_major= 1
      ,http_minor= 0
      ,status_code= 200
      ,response_status= "OK"
      ,num_headers= 2
      ,headers=Dict{String,String}(
          "Transfer-Encoding"=> "chunked"
        , "Content-Type"=> "text/plain"
        }
      ,body_size= 31337*1024
      };
    for (i = 0; i < MAX_CHUNKS; i++) {
    }
    test_message_count_body(&large_chunked);
    free(msg);
  }



  print("response scan 1/2      ");
  test_scan( &responses[TRAILING_SPACE_ON_CHUNKED_BODY]
           , &responses[NO_BODY_HTTP10_KA_204]
           , &responses[NO_REASON_PHRASE]
           );

  print("response scan 2/2      ");
  test_scan( &responses[BONJOUR_MADAME_FR]
           , &responses[UNDERSTORE_HEADER_KEY]
           , &responses[NO_CARRIAGE_RET]
           );

  puts("responses okay");


  #/ REQUESTS

  test_simple("GET / HTP/1.1\r\n\r\n", HPE_INVALID_VERSION);

  # Extended characters - see nodejs/test/parallel/test-http-headers-obstext.js
  test_simple("GET / HTTP/1.1\r\n"
              "Test: Düsseldorf\r\n",
              HPE_OK);

  # Well-formed but incomplete
  test_simple("GET / HTTP/1.1\r\n"
              "Content-Type: text/plain\r\n"
              "Content-Length: 6\r\n"
              "\r\n"
              "fooba",
              HPE_OK);

  static const char *all_methods[] = {
    "DELETE",
    "GET",
    "HEAD",
    "POST",
    "PUT",
    #"CONNECT", #CONNECT can't be tested like other methods, it's a tunnel
    "OPTIONS",
    "TRACE",
    "COPY",
    "LOCK",
    "MKCOL",
    "MOVE",
    "PROPFIND",
    "PROPPATCH",
    "SEARCH",
    "UNLOCK",
    "BIND",
    "REBIND",
    "UNBIND",
    "ACL",
    "REPORT",
    "MKACTIVITY",
    "CHECKOUT",
    "MERGE",
    "M-SEARCH",
    "NOTIFY",
    "SUBSCRIBE",
    "UNSUBSCRIBE",
    "PATCH",
    "PURGE",
    "MKCALENDAR",
    "LINK",
    "UNLINK",
    0 };
  const char **this_method;
  for (this_method = all_methods; *this_method; this_method++) {
    char buf[200];
    sprint(buf, "%s / HTTP/1.1\r\n\r\n", *this_method);
    test_simple(buf, HPE_OK);
  }

  static const char *bad_methods[] = {
      "ASDF",
      "C******",
      "COLA",
      "GEM",
      "GETA",
      "M****",
      "MKCOLA",
      "PROPPATCHA",
      "PUN",
      "PX",
      "SA",
      "hello world",
      0 };
  for (this_method = bad_methods; *this_method; this_method++) {
    char buf[200];
    sprint(buf, "%s / HTTP/1.1\r\n\r\n", *this_method);
    test_simple(buf, HPE_INVALID_METHOD);
  }

  # illegal header field name line folding
  test_simple("GET / HTTP/1.1\r\n"
              "name\r\n"
              " : value\r\n"
              "\r\n",
              HPE_INVALID_HEADER_TOKEN);

  const char *dumbfuck2 =
    "GET / HTTP/1.1\r\n"
    "X-SSL-Bullshit:   -----BEGIN CERTIFICATE-----\r\n"
    "\tMIIFbTCCBFWgAwIBAgICH4cwDQYJKoZIhvcNAQEFBQAwcDELMAkGA1UEBhMCVUsx\r\n"
    "\tETAPBgNVBAoTCGVTY2llbmNlMRIwEAYDVQQLEwlBdXRob3JpdHkxCzAJBgNVBAMT\r\n"
    "\tAkNBMS0wKwYJKoZIhvcNAQkBFh5jYS1vcGVyYXRvckBncmlkLXN1cHBvcnQuYWMu\r\n"
    "\tdWswHhcNMDYwNzI3MTQxMzI4WhcNMDcwNzI3MTQxMzI4WjBbMQswCQYDVQQGEwJV\r\n"
    "\tSzERMA8GA1UEChMIZVNjaWVuY2UxEzARBgNVBAsTCk1hbmNoZXN0ZXIxCzAJBgNV\r\n"
    "\tBAcTmrsogriqMWLAk1DMRcwFQYDVQQDEw5taWNoYWVsIHBhcmQYJKoZIhvcNAQEB\r\n"
    "\tBQADggEPADCCAQoCggEBANPEQBgl1IaKdSS1TbhF3hEXSl72G9J+WC/1R64fAcEF\r\n"
    "\tW51rEyFYiIeZGx/BVzwXbeBoNUK41OK65sxGuflMo5gLflbwJtHBRIEKAfVVp3YR\r\n"
    "\tgW7cMA/s/XKgL1GEC7rQw8lIZT8RApukCGqOVHSi/F1SiFlPDxuDfmdiNzL31+sL\r\n"
    "\t0iwHDdNkGjy5pyBSB8Y79dsSJtCW/iaLB0/n8Sj7HgvvZJ7x0fr+RQjYOUUfrePP\r\n"
    "\tu2MSpFyf+9BbC/aXgaZuiCvSR+8Snv3xApQY+fULK/xY8h8Ua51iXoQ5jrgu2SqR\r\n"
    "\twgA7BUi3G8LFzMBl8FRCDYGUDy7M6QaHXx1ZWIPWNKsCAwEAAaOCAiQwggIgMAwG\r\n"
    "\tA1UdEwEB/wQCMAAwEQYJYIZIAYb4QgHTTPAQDAgWgMA4GA1UdDwEB/wQEAwID6DAs\r\n"
    "\tBglghkgBhvhCAQ0EHxYdVUsgZS1TY2llbmNlIFVzZXIgQ2VydGlmaWNhdGUwHQYD\r\n"
    "\tVR0OBBYEFDTt/sf9PeMaZDHkUIldrDYMNTBZMIGaBgNVHSMEgZIwgY+AFAI4qxGj\r\n"
    "\tloCLDdMVKwiljjDastqooXSkcjBwMQswCQYDVQQGEwJVSzERMA8GA1UEChMIZVNj\r\n"
    "\taWVuY2UxEjAQBgNVBAsTCUF1dGhvcml0eTELMAkGA1UEAxMCQ0ExLTArBgkqhkiG\r\n"
    "\t9w0BCQEWHmNhLW9wZXJhdG9yQGdyaWQtc3VwcG9ydC5hYy51a4IBADApBgNVHRIE\r\n"
    "\tIjAggR5jYS1vcGVyYXRvckBncmlkLXN1cHBvcnQuYWMudWswGQYDVR0gBBIwEDAO\r\n"
    "\tBgwrBgEEAdkvAQEBAQYwPQYJYIZIAYb4QgEEBDAWLmh0dHA6Ly9jYS5ncmlkLXN1\r\n"
    "\tcHBvcnQuYWMudmT4sopwqlBWsvcHViL2NybC9jYWNybC5jcmwwPQYJYIZIAYb4QgEDBDAWLmh0\r\n"
    "\tdHA6Ly9jYS5ncmlkLXN1cHBvcnQuYWMudWsvcHViL2NybC9jYWNybC5jcmwwPwYD\r\n"
    "\tVR0fBDgwNjA0oDKgMIYuaHR0cDovL2NhLmdyaWQt5hYy51ay9wdWIv\r\n"
    "\tY3JsL2NhY3JsLmNybDANBgkqhkiG9w0BAQUFAAOCAQEAS/U4iiooBENGW/Hwmmd3\r\n"
    "\tXCy6Zrt08YjKCzGNjorT98g8uGsqYjSxv/hmi0qlnlHs+k/3Iobc3LjS5AMYr5L8\r\n"
    "\tUO7OSkgFFlLHQyC9JzPfmLCAugvzEbyv4Olnsr8hbxF1MbKZoQxUZtMVu29wjfXk\r\n"
    "\thTeApBv7eaKCWpSp7MCbvgzm74izKhu3vlDk9w6qVrxePfGgpKPqfHiOoGhFnbTK\r\n"
    "\twTC6o2xq5y0qZ03JonF7OJspEd3I5zKY3E+ov7/ZhW6DqT8UFvsAdjvQbXyhV8Eu\r\n"
    "\tYhixw1aKEPzNjNowuIseVogKOLXxWI5vAi5HgXdS0/ES5gDGsABo4fqovUKlgop3\r\n"
    "\tRA==\r\n"
    "\t-----END CERTIFICATE-----\r\n"
    "\r\n";
  test_simple(dumbfuck2, HPE_OK);

  const char *corrupted_connection =
    "GET / HTTP/1.1\r\n"
    "Host: www.example.com\r\n"
    "Connection\r\033\065\325eep-Alive\r\n"
    "Accept-Encoding: gzip\r\n"
    "\r\n";
  test_simple(corrupted_connection, HPE_INVALID_HEADER_TOKEN);

  const char *corrupted_header_name =
    "GET / HTTP/1.1\r\n"
    "Host: www.example.com\r\n"
    "X-Some-Header\r\033\065\325eep-Alive\r\n"
    "Accept-Encoding: gzip\r\n"
    "\r\n";
  test_simple(corrupted_header_name, HPE_INVALID_HEADER_TOKEN);

#if 0
  # NOTE(Wed Nov 18 11:57:27 CET 2009) this seems okay. we just read body
  # until EOF.
  #
  # no content-length
  # error if there is a body without content length
  const char *bad_get_no_headers_no_body = "GET /bad_get_no_headers_no_body/world HTTP/1.1\r\n"
                                           "Accept: */*\r\n"
                                           "\r\n"
                                           "HELLO";
  test_simple(bad_get_no_headers_no_body, 0);
#endif
  #= TODO sending junk and large headers gets rejected =#


  #= check to make sure our predefined requests are okay =#
  for (i = 0; requests[i].name; i++) {
    test_message(&requests[i]);
  }

  for (i = 0; i < request_count; i++) {
    test_message_pause(&requests[i]);
  }

  for (i = 0; i < request_count; i++) {
    if (!requests[i]should_keep_alive) continue;
    for (j = 0; j < request_count; j++) {
      if (!requests[j]should_keep_alive) continue;
      for (k = 0; k < request_count; k++) {
        test_multiple3(&requests[i], &requests[j], &requests[k]);
      }
    }
  }

  print("request scan 1/4      ");
  test_scan( &requests[GET_NO_HEADERS_NO_BODY]
           , &requests[GET_ONE_HEADER_NO_BODY]
           , &requests[GET_NO_HEADERS_NO_BODY]
           );

  print("request scan 2/4      ");
  test_scan( &requests[POST_CHUNKED_ALL_YOUR_BASE]
           , &requests[POST_IDENTITY_BODY_WORLD]
           , &requests[GET_FUNKY_CONTENT_LENGTH]
           );

  print("request scan 3/4      ");
  test_scan( &requests[TWO_CHUNKS_MULT_ZERO_END]
           , &requests[CHUNKED_W_TRAILING_HEADERS]
           , &requests[CHUNKED_W_BULLSHIT_AFTER_LENGTH]
           );

  print("request scan 4/4      ");
  test_scan( &requests[QUERY_URL_WITH_QUESTION_MARK_GET]
           , &requests[PREFIX_NEWLINE_GET ]
           , &requests[CONNECT_REQUEST]
           );

  println("requests okay");

  return 0;
end