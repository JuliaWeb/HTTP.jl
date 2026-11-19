module ParserTest

using Base.Test

import ..HTTP
import ..HTTP.pairs

using HTTP.Messages
using HTTP.Parsers

const DEFAULT_PARSER = Parser()

import Base.==

const Headers = Vector{Pair{String,String}}

==(a::Request,b::Request) = (a.method         == b.method)    &&
                            (a.version        == b.version)   &&
                            (a.headers        == b.headers)   &&
                            (a.body           == b.body)


function HTTP.IOExtras.unread!(io::IOBuffer, bytes)
    l = length(bytes)
    if l == 0
        return
    end

    @assert bytes == io.data[io.ptr - l:io.ptr-1]

    if io.seekable
        seek(io, io.ptr - (l + 1))
        return
    end

    println("WARNING: Can't unread! non-seekable IOBuffer")
    println("         Discarding $(length(bytes)) bytes!")
    @assert false
    return
end


function HTTP.IOExtras.unread!(io::BufferStream, bytes)
    if length(bytes) == 0
        return
    end
    if nb_available(io) > 0
        buf = readavailable(io)
        write(io, bytes)
        write(io, buf)
    else
        write(io, bytes)
    end
    return
end

function parse!(parser::Parser, message::Messages.Message, body, bytes)::Int

    l = length(bytes)
    count = 0
    while count < l
        if !headerscomplete(parser)
            excess = parseheaders(parser, bytes) do h
                appendheader(message, h)
            end
            readstartline!(parser.message, message)
        else
            fragment, excess = parsebody(parser, bytes)
            write(body, fragment)
        end
        count += length(bytes) - length(excess)
        bytes = excess
        if messagecomplete(parser)
            break
        end
    end
    return count
end


mutable struct Message
  name::String
  raw::String
  method::String
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
  headers::Headers
  should_keep_alive::Bool
  upgrade::String
  http_major::Int
  http_minor::Int

  Message(name::String) = new(name, "", "GET", 200, "", "", "", "", "", "", 0, "", "", "", 0, Headers(), true, "", 1, 1)
end

function Message(; name::String="", kwargs...)
  m = Message(name)
  for (k, v) in pairs(kwargs)
      try
          setfield!(m, k, v)
      catch e
          error("error setting k=$k, v=$v")
      end
  end
  return m
end


#=
FIXME request tests for:
 -  No response body for 100 <= r.status < 200 ||
                      r.status == 204 ||
                      r.status == 304 || 
                      method(r) in ("HEAD", "CONNECT")

 = No request body for method(r) in ("GET", "HEAD", "CONNECT")
=#
 



#= * R E Q U E S T S * =#
const requests = Message[
Message(name= "curl get"
,raw= "GET /test HTTP/1.1\r\n" *
       "User-Agent: curl/7.18.0 (i486-pc-linux-gnu) libcurl/7.18.0 OpenSSL/0.9.8g zlib/1.2.3.3 libidn/1.1\r\n" *
       "Host:0.0.0.0=5000\r\n" * # missing space after colon
       "Accept: */*\r\n" *
       "\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,method= "GET"
,query_string= ""
,fragment= ""
,request_path= "/test"
,request_url= "/test"
,num_headers= 3
,headers=[
    "User-Agent"=> "curl/7.18.0 (i486-pc-linux-gnu) libcurl/7.18.0 OpenSSL/0.9.8g zlib/1.2.3.3 libidn/1.1"
  , "Host"=> "0.0.0.0=5000"
  , "Accept"=> "*/*"
  ]
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
,method= "GET"
,query_string= ""
,fragment= ""
,request_path= "/favicon.ico"
,request_url= "/favicon.ico"
,num_headers= 8
,headers=[
    "Host"=> "0.0.0.0=5000"
  , "User-Agent"=> "Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9) Gecko/2008061015 Firefox/3.0"
  , "Accept"=> "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
  , "Accept-Language"=> "en-us,en;q=0.5"
  , "Accept-Encoding"=> "gzip,deflate"
  , "Accept-Charset"=> "ISO-8859-1,utf-8;q=0.7,*;q=0.7"
  , "Keep-Alive"=> "300"
  , "Connection"=> "keep-alive"
]
,body= ""
), Message(name= "abcdefgh"
,raw= "GET /abcdefgh HTTP/1.1\r\n" *
       "aaaaaaaaaaaaa:++++++++++\r\n" *
       "\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,method= "GET"
,query_string= ""
,fragment= ""
,request_path= "/abcdefgh"
,request_url= "/abcdefgh"
,num_headers= 1
,headers=[
    "Aaaaaaaaaaaaa"=>  "++++++++++"
]
,body= ""
), Message(name= "fragment in url"
,raw= "GET /forums/1/topics/2375?page=1#posts-17408 HTTP/1.1\r\n" *
       "\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,method= "GET"
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
,method= "GET"
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
,method= "GET"
,query_string= ""
,fragment= ""
,request_path= "/get_one_header_no_body"
,request_url= "/get_one_header_no_body"
,num_headers= 1
,headers=[
     "Accept" => "*/*"
]
,body= ""
), Message(name= "get funky content length body hello"
,raw= "GET /get_funky_content_length_body_hello HTTP/1.0\r\n" *
       "conTENT-Length: 5\r\n" *
       "\r\n" *
       "HELLO"
,should_keep_alive= false
,http_major= 1
,http_minor= 0
,method= "GET"
,query_string= ""
,fragment= ""
,request_path= "/get_funky_content_length_body_hello"
,request_url= "/get_funky_content_length_body_hello"
,num_headers= 1
,headers=[
     "Content-Length" => "5"
]
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
,method= "POST"
,query_string= "q=search"
,fragment= "hey"
,request_path= "/post_identity_body_world"
,request_url= "/post_identity_body_world?q=search#hey"
,num_headers= 3
,headers=[
    "Accept"=> "*/*"
  , "Transfer-Encoding"=> "identity"
  , "Content-Length"=> "5"
]
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
,method= "POST"
,query_string= ""
,fragment= ""
,request_path= "/post_chunked_all_your_base"
,request_url= "/post_chunked_all_your_base"
,num_headers= 1
,headers=[
    "Transfer-Encoding" => "chunked"
]
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
,method= "POST"
,query_string= ""
,fragment= ""
,request_path= "/two_chunks_mult_zero_end"
,request_url= "/two_chunks_mult_zero_end"
,num_headers= 1
,headers=[
    "Transfer-Encoding"=> "chunked"
]
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
,method= "POST"
,query_string= ""
,fragment= ""
,request_path= "/chunked_w_trailing_headers"
,request_url= "/chunked_w_trailing_headers"
,num_headers= 3
,headers=[
    "Transfer-Encoding"=>  "chunked"
  , "Vary"=> "*"
  , "Content-Type"=> "text/plain"
]
,body= "hello world"
), Message(name= "with excessss after the length"
,raw= "POST /chunked_w_excessss_after_length HTTP/1.1\r\n" *
       "Transfer-Encoding: chunked\r\n" *
       "\r\n" *
       "5; ihatew3;whattheheck=aretheseparametersfor\r\nhello\r\n" *
       "6; blahblah; blah\r\n world\r\n" *
       "0\r\n" *
       "\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,method= "POST"
,query_string= ""
,fragment= ""
,request_path= "/chunked_w_excessss_after_length"
,request_url= "/chunked_w_excessss_after_length"
,num_headers= 1
,headers=[
    "Transfer-Encoding"=> "chunked"
]
,body= "hello world"
), Message(name= "with quotes"
,raw= "GET /with_\"stupid\"_quotes?foo=\"bar\" HTTP/1.1\r\n\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,method= "GET"
,query_string= "foo=\"bar\""
,fragment= ""
,request_path= "/with_\"stupid\"_quotes"
,request_url= "/with_\"stupid\"_quotes?foo=\"bar\""
,num_headers= 0
,headers=Headers()
,body= ""
), Message(name = "apachebench get"
,raw= "GET /test HTTP/1.0\r\n" *
       "Host: 0.0.0.0:5000\r\n" *
       "User-Agent: ApacheBench/2.3\r\n" *
       "Accept: */*\r\n\r\n"
,should_keep_alive= false
,http_major= 1
,http_minor= 0
,method= "GET"
,query_string= ""
,fragment= ""
,request_path= "/test"
,request_url= "/test"
,num_headers= 3
,headers=[ "Host"=> "0.0.0.0:5000"
           , "User-Agent"=> "ApacheBench/2.3"
           , "Accept"=> "*/*"
         ]
,body= ""
), Message(name = "query url with question mark"
,raw= "GET /test.cgi?foo=bar?baz HTTP/1.1\r\n\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,method= "GET"
,query_string= "foo=bar?baz"
,fragment= ""
,request_path= "/test.cgi"
,request_url= "/test.cgi?foo=bar?baz"
,num_headers= 0
,headers=Headers()
,body= ""
), Message(name = "newline prefix get"
,raw= "\r\nGET /test HTTP/1.1\r\n\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,method= "GET"
,query_string= ""
,fragment= ""
,request_path= "/test"
,request_url= "/test"
,num_headers= 0
,headers=Headers()
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
,method= "GET"
,query_string= ""
,fragment= ""
,request_path= "/demo"
,request_url= "/demo"
,num_headers= 7
,upgrade="Hot diggity dogg"
,headers=[ "Host"=> "example.com"
           , "Connection"=> "Upgrade"
           , "Sec-Websocket-Key2"=> "12998 5 Y3 1  .P00"
           , "Sec-Websocket-Protocol"=> "sample"
           , "Upgrade"=> "WebSocket"
           , "Sec-Websocket-Key1"=> "4 @1  46546xW%0l 1 5"
           , "Origin"=> "http://example.com"
         ]
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
,method= "CONNECT"
,query_string= ""
,fragment= ""
,request_path= ""
,host="0-home0.netscape.com"
,port="443"
,request_url= "0-home0.netscape.com:443"
,num_headers= 2
,upgrade="some data\r\nand yet even more data"
,headers=[ "User-Agent"=> "Mozilla/1.1N"
           , "Proxy-Authorization"=> "basic aGVsbG86d29ybGQ="
         ]
,body= ""
), Message(name= "report request"
,raw= "REPORT /test HTTP/1.1\r\n" *
       "\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,method= "REPORT"
,query_string= ""
,fragment= ""
,request_path= "/test"
,request_url= "/test"
,num_headers= 0
,headers=Headers()
,body= ""
), Message(name= "request with no http version"
,raw= "GET /\r\n" *
       "\r\n"
,should_keep_alive= false
,http_major= 0
,http_minor= 9
,method= "GET"
,query_string= ""
,fragment= ""
,request_path= "/"
,request_url= "/"
,num_headers= 0
,headers=Headers()
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
,method= "MSEARCH"
,query_string= ""
,fragment= ""
,request_path= "*"
,request_url= "*"
,num_headers= 3
,headers=[ "Host"=> "239.255.255.250:1900"
           , "Man"=> "\"ssdp:discover\""
           , "St"=> "\"ssdp:all\""
         ]
,body= ""
), Message(name= "host terminated by a query string"
,raw= "GET http://hypnotoad.org?hail=all HTTP/1.1\r\n" *
       "\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,method= "GET"
,query_string= "hail=all"
,fragment= ""
,request_path= ""
,request_url= "http://hypnotoad.org?hail=all"
,host= "hypnotoad.org"
,num_headers= 0
,headers=Headers()
,body= ""
), Message(name= "host:port terminated by a query string"
,raw= "GET http://hypnotoad.org:1234?hail=all HTTP/1.1\r\n" *
       "\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,method= "GET"
,query_string= "hail=all"
,fragment= ""
,request_path= ""
,request_url= "http://hypnotoad.org:1234?hail=all"
,host= "hypnotoad.org"
,port= "1234"
,num_headers= 0
,headers=Headers()
,body= ""
), Message(name= "host:port terminated by a space"
,raw= "GET http://hypnotoad.org:1234 HTTP/1.1\r\n" *
       "\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,method= "GET"
,query_string= ""
,fragment= ""
,request_path= ""
,request_url= "http://hypnotoad.org:1234"
,host= "hypnotoad.org"
,port= "1234"
,num_headers= 0
,headers=Headers()
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
,method= "PATCH"
,query_string= ""
,fragment= ""
,request_path= "/file.txt"
,request_url= "/file.txt"
,num_headers= 4
,headers=[ "Host"=> "www.example.com"
           , "Content-Type"=> "application/example"
           , "If-Match"=> "\"e0023aa4e\""
           , "Content-Length"=> "10"
         ]
,body= "cccccccccc"
), Message(name = "connect caps request"
,raw= "CONNECT HOME0.NETSCAPE.COM:443 HTTP/1.0\r\n" *
       "User-agent: Mozilla/1.1N\r\n" *
       "Proxy-authorization: basic aGVsbG86d29ybGQ=\r\n" *
       "\r\n"
,should_keep_alive= false
,http_major= 1
,http_minor= 0
,method= "CONNECT"
,query_string= ""
,fragment= ""
,request_path= ""
,request_url= "HOME0.NETSCAPE.COM:443"
,host="HOME0.NETSCAPE.COM"
,port="443"
,num_headers= 2
,upgrade=""
,headers=[ "User-Agent"=> "Mozilla/1.1N"
           , "Proxy-Authorization"=> "basic aGVsbG86d29ybGQ="
         ]
,body= ""
), Message(name= "utf-8 path request"
,raw= "GET /δ¶/δt/pope?q=1#narf HTTP/1.1\r\n" *
       "Host: github.com\r\n" *
       "\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,method= "GET"
,query_string= "q=1"
,fragment= "narf"
,request_path= "/δ¶/δt/pope"
,request_url= "/δ¶/δt/pope?q=1#narf"
,num_headers= 1
,headers=["Host" => "github.com"]
,body= ""
), Message(name = "hostname underscore"
,raw= "CONNECT home_0.netscape.com:443 HTTP/1.0\r\n" *
       "User-agent: Mozilla/1.1N\r\n" *
       "Proxy-authorization: basic aGVsbG86d29ybGQ=\r\n" *
       "\r\n"
,should_keep_alive= false
,http_major= 1
,http_minor= 0
,method= "CONNECT"
,query_string= ""
,fragment= ""
,request_path= ""
,request_url= "home_0.netscape.com:443"
,host="home_0.netscape.com"
,port="443"
,num_headers= 2
,upgrade=""
,headers=[ "User-Agent"=> "Mozilla/1.1N"
           , "Proxy-Authorization"=> "basic aGVsbG86d29ybGQ="
         ]
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
,method= "POST"
,query_string= ""
,fragment= ""
,request_path= "/"
,request_url= "/"
,num_headers= 3
,upgrade= ""
,headers=[ "Host"=> "www.example.com"
           , "Content-Type"=> "application/x-www-form-urlencoded"
           , "Content-Length"=> "4"
         ]
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
,method= "POST"
,query_string= ""
,fragment= ""
,request_path= "/"
,request_url= "/"
,num_headers= 4
,upgrade= ""
,headers=[ "Host"=> "www.example.com"
           , "Content-Type"=> "application/x-www-form-urlencoded"
           , "Content-Length"=> "4"
           , "Connection"=> "close"
         ]
,body= "q=42"
), Message(name = "PURGE request"
,raw= "PURGE /file.txt HTTP/1.1\r\n" *
       "Host: www.example.com\r\n" *
       "\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,method= "PURGE"
,query_string= ""
,fragment= ""
,request_path= "/file.txt"
,request_url= "/file.txt"
,num_headers= 1
,headers=[ "Host"=> "www.example.com" ]
,body= ""
), Message(name = "SEARCH request"
,raw= "SEARCH / HTTP/1.1\r\n" *
       "Host: www.example.com\r\n" *
       "\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,method= "SEARCH"
,query_string= ""
,fragment= ""
,request_path= "/"
,request_url= "/"
,num_headers= 1
,headers=[ "Host"=> "www.example.com"]
,body= ""
), Message(name= "host:port and basic_auth"
,raw= "GET http://a%12:b!&*\$@hypnotoad.org:1234/toto HTTP/1.1\r\n" *
       "\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,method= "GET"
,fragment= ""
,request_path= "/toto"
,request_url= "http://a%12:b!&*\$@hypnotoad.org:1234/toto"
,host= "hypnotoad.org"
,userinfo= "a%12:b!&*\$"
,port= "1234"
,num_headers= 0
,headers=Headers()
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
,method= "POST"
,request_path= "/demo"
,request_url= "/demo"
,num_headers= 4
,upgrade="Hot diggity dogg"
,headers=[ "Host"=> "example.com"
           , "Connection"=> "Upgrade"
           , "Upgrade"=> "HTTP/2.0"
           , "Content-Length"=> "15"
         ]
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
,method= "CONNECT"
,request_url= "foo.bar.com:443"
,host="foo.bar.com"
,port="443"
,num_headers= 3
,upgrade="blarfcicle"
,headers=[ "User-Agent"=> "Mozilla/1.1N"
           , "Proxy-Authorization"=> "basic aGVsbG86d29ybGQ="
           , "Content-Length"=> "10"
         ]
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
,method= "LINK"
,request_path= "/images/my_dog.jpg"
,request_url= "/images/my_dog.jpg"
,query_string= ""
,fragment= ""
,num_headers= 2
,headers=[ "Host"=> "example.com"
           , "Link"=> "<http://example.com/profiles/joe>; rel=\"tag\", <http://example.com/profiles/sally>; rel=\"tag\""
         ]
,body= ""
), Message(name = "link request"
,raw= "UNLINK /images/my_dog.jpg HTTP/1.1\r\n" *
       "Host: example.com\r\n" *
       "Link: <http://example.com/profiles/sally>; rel=\"tag\"\r\n" *
       "\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,method= "UNLINK"
,request_path= "/images/my_dog.jpg"
,request_url= "/images/my_dog.jpg"
,query_string= ""
,fragment= ""
,num_headers= 2
,headers=[ "Host"=> "example.com"
     , "Link"=> "<http://example.com/profiles/sally>; rel=\"tag\""
         ]
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
,method= "GET"
,query_string= ""
,fragment= ""
,request_path= "/demo"
,request_url= "/demo"
,num_headers= 7
,upgrade="Hot diggity dogg"
,headers=[ "Host"=> "example.com"
           , "Connection"=> "Something, Upgrade, ,Keep-Alive"
           , "Sec-Websocket-Key2"=> "12998 5 Y3 1  .P00"
           , "Sec-Websocket-Protocol"=> "sample"
           , "Upgrade"=> "WebSocket"
           , "Sec-Websocket-Key1"=> "4 @1  46546xW%0l 1 5"
           , "Origin"=> "http://example.com"
         ]
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
,method= "GET"
,query_string= ""
,fragment= ""
,request_path= "/"
,request_url= "/"
,num_headers= 5
,headers=[ "Line1"=> "abc\tdef ghi\t\tjkl  mno \t \tqrs"
           , "Line2"=> "line2\t"
           , "Line3"=> "line3"
           , "Line4"=> ""
           , "Connection"=> "close"
         ]
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
,method= "GET"
,query_string= ""
,fragment= ""
,request_path= "/demo"
,request_url= "/demo"
,num_headers= 2
,upgrade="Hot diggity dogg"
,headers=[ "Connection"=> "keep-alive, upgrade"
           , "Upgrade"=> "WebSocket"
         ]
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
,method= "GET"
,query_string= ""
,fragment= ""
,request_path= "/demo"
,request_url= "/demo"
,num_headers= 2
,upgrade="Hot diggity dogg"
,headers=[ "Connection"=> "keep-alive,  upgrade"
           , "Upgrade"=> "WebSocket"
         ]
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
,method= "GET"
,query_string= ""
,fragment= ""
,request_path= "/"
,request_url= "/"
,num_headers= 5
,headers=[ "Line1"=> "abc\tdef ghi\t\tjkl  mno \t \tqrs"
           , "Line2"=> "line2\t"
           , "Line3"=> "line3"
           , "Line4"=> ""
           , "Connection"=> "close"
         ]
,body= ""
)
]

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
,headers=[
    "Location"=> "http://www.google.com/"
  , "Content-Type"=> "text/html; charset=UTF-8"
  , "Date"=> "Sun, 26 Apr 2009 11:11:49 GMT"
  , "Expires"=> "Tue, 26 May 2009 11:11:49 GMT"
  , "X-\$prototypebi-Version"=> "1.6.0.3"
  , "Cache-Control"=> "public, max-age=2592000"
  , "Server"=> "gws"
  , "Content-Length"=> "219  "
]
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
,headers=[
    "Date"=> "Tue, 04 Aug 2009 07:59:32 GMT"
  , "Server"=> "Apache"
  , "X-Powered-By"=> "Servlet/2.5 JSP/2.1"
  , "Content-Type"=> "text/xml; charset=utf-8"
  , "Connection"=> "close"
]
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
,headers=Headers()
,body_size= 0
,body= ""
), Message(name= "301 no response phrase"
,raw= "HTTP/1.1 301\r\n\r\n"
,should_keep_alive = false
,http_major= 1
,http_minor= 1
,status_code= 301
,response_status= "Moved Permanently"
,num_headers= 0
,headers=Headers()
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
,headers=[
    "Content-Type"=> "text/plain"
  , "Transfer-Encoding"=> "chunked"
]
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
,headers=[
    "Content-Type"=> "text/html; charset=utf-8"
  , "Connection"=> "close"
]
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
,headers=[
    "Content-Type"=> "text/html; charset=UTF-8"
  , "Content-Length"=> "11"
  , "Proxy-Connection"=> "close"
  , "Date"=> "Thu, 31 Dec 2009 20:55:48 +0000"
]
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
,headers=[
    "Server"=> "DCLK-AdSvr"
  , "Content-Type"=> "text/xml"
  , "Content-Length"=> "0"
  , "Dclk_imp"=> "v7;x;114750856;0-0;0;17820020;0/0;21603567/21621457/1;;~okv=;dcmt=text/xml;;~cs=o"
]
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
,headers=[
    "Date"=> "Thu, 03 Jun 2010 09:56:32 GMT"
  , "Server"=> "Apache/2.2.3 (Red Hat)"
  , "Cache-Control"=> "public"
  , "Pragma"=> ""
  , "Location"=> "http://www.bonjourmadame.fr/"
  , "Vary"=>  "Accept-Encoding"
  , "Content-Length"=> "0"
  , "Content-Type"=> "text/html; charset=UTF-8"
  , "Connection"=> "keep-alive"
]
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
,headers=[
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
]
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
,response_status= "Internal Server Error"
,num_headers= 3
,headers=[
    "Date"=> "Fri, 5 Nov 2010 23:07:12 GMT+2"
  , "Content-Length"=> "0"
  , "Connection"=> "close"
]
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
,headers=Headers()
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
,headers=[
    "Content-Type"=> "text/plain"
]
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
,headers=[
    "Connection"=> "keep-alive"
]
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
,response_status= "No Content"
,num_headers= 1
,headers=[
    "Connection"=> "keep-alive"
]
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
,headers=Headers()
,body_size= 0
,body= ""
), Message(name= "HTTP/1.1 with a 204 status"
,raw= "HTTP/1.1 204 No content\r\n" *
       "\r\n"
,should_keep_alive= true
,http_major= 1
,http_minor= 1
,status_code= 204
,response_status= "No Content"
,num_headers= 0
,headers=Headers()
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
,response_status= "No Content"
,num_headers= 1
,headers=[
    "Connection"=> "close"
]
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
,headers=[
    "Transfer-Encoding"=> "chunked"
]
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
,headers=[
    "Server"=>  "Microsoft-IIS/6.0"
  , "X-Powered-By"=> "ASP.NET"
  , "En-Us content-Type"=> "text/xml"
  , "Content-Type"=> "text/xml"
  , "Content-Length"=> "16"
  , "Date"=> "Fri, 23 Jul 2010 18:45:38 GMT"
  , "Connection"=> "keep-alive"
]
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
,response_status= "Moved Permanently"
,num_headers= 9
,headers=[ "Date"=> "Wed, 15 May 2013 17:06:33 GMT"
           , "Server"=> "Server"
           , "X-Amz-Id-1"=> "0GPHKXSJQ826RK7GZEB2"
           , "P3p"=> "policyref=\"http://www.amazon.com/w3c/p3p.xml\",CP=\"CAO DSP LAW CUR ADM IVAo IVDo CONo OTPo OUR DELi PUBi OTRi BUS PHY ONL UNI PUR FIN COM NAV INT DEM CNT STA HEA PRE LOC GOV OTC \""
           , "X-Amz-Id-2"=> "STN69VZxIFSz9YJLbz1GDbxpbjG6Qjmmq5E3DxRhOUw+Et0p4hr7c/Q8qNcx4oAD"
           , "Location"=> "http://www.amazon.com/Dan-Brown/e/B000AP9DSU/ref=s9_pop_gw_al1?_encoding=UTF8&refinementId=618073011&pf_rd_m=ATVPDKIKX0DER&pf_rd_s=center-2&pf_rd_r=0SHYY5BZXN3KR20BNFAY&pf_rd_t=101&pf_rd_p=1263340922&pf_rd_i=507846"
           , "Vary"=> "Accept-Encoding,User-Agent"
           , "Content-Type"=> "text/html; charset=ISO-8859-1"
           , "Transfer-Encoding"=> "chunked"
         ]
,body= "\n"
), Message(name= "empty reason phrase after space"
,raw= "HTTP/1.1 200 \r\n" *
       "\r\n"
,should_keep_alive= false
,http_major= 1
,http_minor= 1
,status_code= 200
,response_status= "OK"
,num_headers= 0
,headers=Headers()
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
,headers=[ "Content-Length-X"=> "0"
           , "Transfer-Encoding"=> "chunked"
         ]
,body= "OK"
)
]

@testset "HTTP.parse" begin

  @testset "HTTP.parse(HTTP.Request, str)" begin
      for req in requests, t in [-1, 0, 1, 2, 3, 4, 11, 13, 17, 19, 23, 29, 31, 32]

          println("TEST - parser.jl - Request $t: $(req.name)")
          upgrade = Ref{SubArray{UInt8, 1}}()
          r = Request()
          p = Parser()
          b = IOBuffer()
          bytes = Vector{UInt8}(req.raw)
          sz = t
          if t > 0
              for i in 1:sz:length(bytes)
                  parse!(p, r, b, view(bytes, i:min(i+sz-1, length(bytes))))
              end
              r.body = take!(b)
          elseif t < 0
              i = rand(2:length(bytes))
              parse!(p, r, b, bytes[1:i-1])
              parse!(p, r, b, bytes[i:end])
              r.body = take!(b)
          else
              r = Request(req.raw)
              #r = HTTP.parse(HTTP.Request, req.raw; extraref=upgrade)
          end
          uri = parse(HTTP.URI, r.uri; isconnect= req.method == "CONNECT")
          @test r.version.major == req.http_major
          @test r.version.minor == req.http_minor
          @test r.method == string(req.method)
          @test uri.query == req.query_string
          @test uri.fragment == req.fragment
          @test uri.path == req.request_path
          @test uri.host == req.host
          @test uri.userinfo == req.userinfo
          @test uri.port in (req.port, "80", "443")
          @test string(uri) == req.request_url
          @test length(r.headers) == req.num_headers
          @test Dict(HTTP.CanonicalizeRequest.canonicalizeheaders(r.headers)) == Dict(req.headers)
          @test String(r.body) == req.body
# FIXME          @test HTTP.http_should_keep_alive(HTTP.DEFAULT_PARSER) == req.should_keep_alive

          if isassigned(upgrade)
              @show String(collect(upgrade[]))
          end
# FIXME          @test t != 0 ||
#                req.upgrade == "" && !isassigned(upgrade) ||
#                String(collect(upgrade[])) == req.upgrade
      end

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

      req = Request("GET", "http://www.techcrunch.com/")
      req.headers = ["Host"=>"www.techcrunch.com","User-Agent"=>"Fake","Accept"=>"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8","Accept-Language"=>"en-us,en;q=0.5","Accept-Encoding"=>"gzip,deflate","Accept-Charset"=>"ISO-8859-1,utf-8;q=0.7,*;q=0.7","Keep-Alive"=>"300","Content-Length"=>"7","Proxy-Connection"=>"keep-alive"]
      req.body = Vector{UInt8}("1234567")

      @test Request(reqstr).headers == req.headers
      @test Request(reqstr) == req

      reqstr = "GET / HTTP/1.1\r\n" *
               "Host: foo.com\r\n\r\n"

      req = Request("GET", "/")
      req.headers = ["Host"=>"foo.com"]

      @test Request(reqstr) == req

      reqstr = "GET //user@host/is/actually/a/path/ HTTP/1.1\r\n" *
               "Host: test\r\n\r\n"

      req = Request("GET", "//user@host/is/actually/a/path/")
      req.headers = ["Host"=>"test"]

      @test Request(reqstr) == req

      reqstr = "GET ../../../../etc/passwd HTTP/1.1\r\n" *
               "Host: test\r\n\r\n"

      @test_throws ParsingError Request(reqstr)

      reqstr = "GET  HTTP/1.1\r\n" *
               "Host: test\r\n\r\n"

      @test_throws ParsingError Request(reqstr)

      reqstr = "POST / HTTP/1.1\r\n" *
               "Host: foo.com\r\n" *
               "Transfer-Encoding: chunked\r\n\r\n" *
               "3\r\nfoo\r\n" *
               "3\r\nbar\r\n" *
               "0\r\n" *
               "Trailer-Key: Trailer-Value\r\n" *
               "\r\n"

      req = Request()
      req.method = "POST"
      req.uri = "/"
      req.headers = ["Host"=>"foo.com", "Transfer-Encoding"=>"chunked", "Trailer-Key"=>"Trailer-Value"]
      req.body = Vector{UInt8}("foobar")

      @test Request(reqstr) == req

      reqstr = "POST / HTTP/1.1\r\n" *
               "Host: foo.com\r\n" *
               "Transfer-Encoding: chunked\r\n" *
               "Content-Length: 9999\r\n\r\n" * # to be removed.
               "3\r\nfoo\r\n" *
               "3\r\nbar\r\n" *
               "0\r\n" *
               "\r\n"

      @test_throws ParsingError Request(reqstr)

      reqstr = "CONNECT www.google.com:443 HTTP/1.1\r\n\r\n"

      req = Request()
      req.method = "CONNECT"
      req.uri = "www.google.com:443" # FIXME; isconnect=true)

      @test Request(reqstr) == req

      reqstr = "CONNECT 127.0.0.1:6060 HTTP/1.1\r\n\r\n"

      req = Request()
      req.method = "CONNECT"
      req.uri = "127.0.0.1:6060" #FIXME; isconnect=true)

      @test Request(reqstr) == req

      # reqstr = "CONNECT /_goRPC_ HTTP/1.1\r\n\r\n"
      #
      # req = HTTP.Request()
      # req.method = "CONNECT"
      # req.uri = HTTP.URI("/_goRPC_"; isconnect=true)

      # @test HTTP.parse(HTTP.Request, reqstr) == req

      reqstr = "NOTIFY * HTTP/1.1\r\nServer: foo\r\n\r\n"

      req = Request()
      req.method = "NOTIFY"
      req.uri = "*"
      req.headers = ["Server"=>"foo"]

      @test Request(reqstr) == req

      reqstr = "OPTIONS * HTTP/1.1\r\nServer: foo\r\n\r\n"

      req = Request()
      req.method = "OPTIONS"
      req.uri = "*"
      req.headers = ["Server"=>"foo"]

      @test Request(reqstr) == req

      reqstr = "GET / HTTP/1.1\r\nHost: issue8261.com\r\nConnection: close\r\n\r\n"

      req = Request("GET", "/")
      req.headers = ["Host"=>"issue8261.com", "Connection"=>"close"]

      @test Request(reqstr) == req

      reqstr = "HEAD / HTTP/1.1\r\nHost: issue8261.com\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"

      req = Request()
      req.method = "HEAD"
      req.uri = "/"
      req.headers = ["Host"=>"issue8261.com", "Connection"=>"close", "Content-Length"=>"0"]

      @test Request(reqstr) == req

      reqstr = "POST /cgi-bin/process.cgi HTTP/1.1\r\n" *
               "User-Agent: Mozilla/4.0 (compatible; MSIE5.01; Windows NT)\r\n" *
               "Host: www.tutorialspoint.com\r\n" *
               "Content-Type: text/xml; charset=utf-8\r\n" *
               "Content-Length: 19\r\n" *
               "Accept-Language: en-us\r\n" *
               "Accept-Encoding: gzip, deflate\r\n" *
               "Connection: Keep-Alive\r\n\r\n" *
               "first=Zara&last=Ali\r\n\r\n"

      req = Request()
      req.method = "POST"
      req.uri = "/cgi-bin/process.cgi"
      req.headers = ["User-Agent"=>"Mozilla/4.0 (compatible; MSIE5.01; Windows NT)",
                     "Host"=>"www.tutorialspoint.com",
                     "Content-Type"=>"text/xml; charset=utf-8",
                     "Content-Length"=>"19",
                     "Accept-Language"=>"en-us",
                     "Accept-Encoding"=>"gzip, deflate",
                     "Connection"=>"Keep-Alive"]
      req.body = Vector{UInt8}("first=Zara&last=Ali")

      @test Request(reqstr) == req
  end

  @testset "Response(str)" begin
      for resp in responses, t in [0, 1, 2, 3, 4, 11, 13, 17, 19, 23, 29, 31, 32]
          println("TEST - parser.jl - Response $t: $(resp.name)")
          try
              if t > 0
                  r = Response()
                  p = Parser()
                  b = IOBuffer()
                  bytes = Vector{UInt8}(resp.raw)
                  sz = t
                  for i in 1:sz:length(bytes)
                      parse!(p, r, b, view(bytes, i:min(i+sz-1, length(bytes))))
                  end
                  r.body = take!(b)
              else
                  r = Response(resp.raw)
              end
              @test r.version.major == resp.http_major
              @test r.version.minor == resp.http_minor
              @test r.status == resp.status_code
              @test HTTP.Messages.statustext(r) == resp.response_status
              @test length(r.headers) == resp.num_headers
              @test Dict(HTTP.CanonicalizeRequest.canonicalizeheaders(r.headers)) == Dict(resp.headers)
              @test String(r.body) == resp.body
# FIXME              @test HTTP.http_should_keep_alive(HTTP.DEFAULT_PARSER) == resp.should_keep_alive
          catch e
              if HTTP.Parsers.strict && isa(e, ParsingError)
                  println("HTTP.strict is enabled. ParsingError ignored.")
              else
                  rethrow()
              end
          end
      end
  end

  @testset "HTTP.parse errors" begin
      reqstr = "GET / HTTP/1.1\r\n" * "Foo: F\01ailure\r\n\r\n"
      HTTP.Parsers.strict && @test_throws ParsingError Request(reqstr)
      if !HTTP.Parsers.strict
        r = HTTP.parse(HTTP.Messages.Request, reqstr)
        @test r.method == "GET"
        @test r.uri == "/"
        @test length(r.headers) == 1
      end

      reqstr = "GET / HTTP/1.1\r\n" * "Foo: B\02ar\r\n\r\n"
      HTTP.Parsers.strict && @test_throws ParsingError Request(reqstr)
      if !HTTP.Parsers.strict
          r = parse(HTTP.Messages.Request, reqstr)
          @test r.method == "GET"
          @test r.uri == "/"
          @test length(r.headers) == 1
      end

      respstr = "HTTP/1.1 200 OK\r\n" * "Foo: F\01ailure\r\n\r\n"
      HTTP.Parsers.strict && @test_throws ParsingError Response(respstr)
      if !HTTP.Parsers.strict
          r = parse(HTTP.Messages.Response, respstr)
          @test r.status == 200
          @test length(r.headers) == 1
      end

      respstr = "HTTP/1.1 200 OK\r\n" * "Foo: B\02ar\r\n\r\n"
      HTTP.Parsers.strict && @test_throws ParsingError Response(respstr)
      if !HTTP.Parsers.strict
          r = parse(HTTP.Messages.Response, respstr)
          @test r.status == 200
          @test length(r.headers) == 1
      end

      reqstr = "GET / HTTP/1.1\r\n" * "Fo@: Failure"
      HTTP.Parsers.strict && @test_throws ParsingError Request(reqstr)
      !HTTP.Parsers.strict && (@test_throws ParsingError Request(reqstr))

      reqstr = "GET / HTTP/1.1\r\n" * "Foo\01\test: Bar"
      HTTP.Parsers.strict && @test_throws ParsingError Request(reqstr)
      !HTTP.Parsers.strict && (@test_throws ParsingError Request(reqstr))

      respstr = "HTTP/1.1 200 OK\r\n" * "Fo@: Failure"
      HTTP.Parsers.strict && @test_throws ParsingError Response(respstr)
      !HTTP.Parsers.strict && (@test_throws ParsingError Response(respstr))

      respstr = "HTTP/1.1 200 OK\r\n" * "Foo\01\test: Bar"
      HTTP.Parsers.strict && @test_throws ParsingError Response(respstr)
      !HTTP.Parsers.strict && (@test_throws ParsingError Response(respstr))

      reqstr = "GET / HTTP/1.1\r\n" * "Content-Length: 0\r\nContent-Length: 1\r\n\r\n"
      HTTP.Parsers.strict && @test_throws ParsingError Request(reqstr)
      respstr = "HTTP/1.1 200 OK\r\n" * "Content-Length: 0\r\nContent-Length: 1\r\n\r\n"
      HTTP.Parsers.strict && @test_throws ParsingError Response(respstr)

      reqstr = "GET / HTTP/1.1\r\n" * "Transfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n"
      HTTP.Parsers.strict && @test_throws ParsingError Request(reqstr)
      respstr = "HTTP/1.1 200 OK\r\n" * "Transfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n"
      HTTP.Parsers.strict && @test_throws ParsingError Response(respstr)

      reqstr = "GET / HTTP/1.1\r\n" * "Foo: 1\rBar: 1\r\n\r\n"
      HTTP.Parsers.strict && @test_throws ParsingError Request(reqstr)
      respstr = "HTTP/1.1 200 OK\r\n" * "Foo: 1\rBar: 1\r\n\r\n"
      HTTP.Parsers.strict && @test_throws ParsingError Response(respstr)


      for r in ((Request, "GET / HTTP/1.1\r\n"), (Response, "HTTP/1.0 200 OK\r\n"))
          R = r[1]()
          b = IOBuffer()
          p = Parser()
          n = parse!(Parser(), R, b, r[2])
          @test !headerscomplete(p)
          @test !messagecomplete(p)
          @test n == length(Vector{UInt8}(r[2]))
      end

      buf = "GET / HTTP/1.1\r\nheader: value\nhdr: value\r\n"
      @test_throws EOFError r = Request(buf)

      respstr = "HTTP/1.1 200 OK\r\n" * "Content-Length: " * "1844674407370955160" * "\r\n\r\n"
      r = Response()
      b = IOBuffer()
      p = Parser()
      parse!(p, r, b, respstr)
      @test r.status == 200
      @test r.headers == ["Content-Length"=>"1844674407370955160"]

      respstr = "HTTP/1.1 200 OK\r\n" * "Content-Length: " * "18446744073709551615" * "\r\n\r\n"
      e = try Response(respstr) catch e e end
      @test isa(e, ParsingError) && e.code == Parsers.HPE_INVALID_CONTENT_LENGTH

      respstr = "HTTP/1.1 200 OK\r\n" * "Content-Length: " * "18446744073709551616" * "\r\n\r\n"
      e = try Response(respstr) catch e e end
      @test isa(e, ParsingError) && e.code == Parsers.HPE_INVALID_CONTENT_LENGTH

      respstr = "HTTP/1.1 200 OK\r\n" * "Transfer-Encoding: chunked\r\n\r\n" * "FFFFFFFFFFFFFFE" * "\r\n..."
      r = Response()
      p = Parser()
      parse!(p, r, b, respstr)
      @test r.status == 200
      @test r.headers == ["Transfer-Encoding"=>"chunked"]

      respstr = "HTTP/1.1 200 OK\r\n" * "Transfer-Encoding: chunked\r\n\r\n" * "FFFFFFFFFFFFFFF" * "\r\n..."
      e = try Response(respstr) catch e e end
      @test isa(e, ParsingError) && e.code == Parsers.HPE_INVALID_CONTENT_LENGTH
      respstr = "HTTP/1.1 200 OK\r\n" * "Transfer-Encoding: chunked\r\n\r\n" * "10000000000000000" * "\r\n..."
      e = try Response(respstr) catch e e end
      @test isa(e, ParsingError) && e.code == Parsers.HPE_INVALID_CONTENT_LENGTH

      for len in (1000, 100000)
          HTTP.Parsers.reset!(p)
          reqstr = "POST / HTTP/1.0\r\nConnection: Keep-Alive\r\nContent-Length: $len\r\n\r\n"
          r = Request()
          p = Parser()
          parse!(p, r, b, reqstr)
          @test headerscomplete(p)
          @test !messagecomplete(p)
          for i = 1:len-1
              parse!(p, r, b, "a")
              @test headerscomplete(p)
              @test !messagecomplete(p)
          end
          parse!(p, r, b, "a")
          @test headerscomplete(p)
          @test messagecomplete(p)
      end

      for len in (1000, 100000)
          HTTP.Parsers.reset!(p)
          respstr = "HTTP/1.0 200 OK\r\nConnection: Keep-Alive\r\nContent-Length: $len\r\n\r\n"
          r = Response()
          p = Parser()
          parse!(p, r, b, respstr)
          @test headerscomplete(p)
          @test !messagecomplete(p)
          for i = 1:len-1
              parse!(p, r, b, "a")
              @test headerscomplete(p)
              @test !messagecomplete(p)
          end
          parse!(p, r, b, "a")
          @test headerscomplete(p)
          @test messagecomplete(p)
      end

      reqstr = requests[1].raw * requests[2].raw
      r = Request()
      p = Parser()
      n = parse!(p, r, b, reqstr)
      @test headerscomplete(p)
      @test messagecomplete(p)
      ex = Vector{UInt8}(reqstr)[n+1:end]
      HTTP.Parsers.reset!(p)
      parse!(p, r, b, ex)
      @test headerscomplete(p)
      @test messagecomplete(p)

      @test_throws ParsingError Request("GET / HTP/1.1\r\n\r\n")

      r = Request("GET / HTTP/1.1\r\n" * "Test: Düsseldorf\r\n\r\n")
      @test r.headers == ["Test" => "Düsseldorf"]

      r = Response()
      p = Parser()
      b = IOBuffer()
      parse!(p, r, b, "GET / HTTP/1.1\r\n" * "Content-Type: text/plain\r\n" * "Content-Length: 6\r\n\r\n" * "fooba")
      @test String(take!(b)) == "fooba"

      for m in instances(Parsers.Method)
          m in (Parsers.NOMETHOD, Parsers.CONNECT) && continue
          me = m == Parsers.MSEARCH ? "M-SEARCH" : "$m"
          r = Request("$me / HTTP/1.1\r\n\r\n")
          @test r.method == string(m)
      end

      for m in ("ASDF","C******","COLA","GEM","GETA","M****","MKCOLA","PROPPATCHA","PUN","PX","SA","hello world")
          @test_throws ParsingError Request("$m / HTTP/1.1\r\n\r\n")
      end

      @test_throws ParsingError Request("GET / HTTP/1.1\r\n" * "name\r\n" * " : value\r\n\r\n")

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

      r = Request(reqstr)
      @test r.method == "GET"

      @test "GET / HTTP/1.1X-SSL-FoooBarr:   $(header(r, "X-SSL-FoooBarr"))" == replace(reqstr, "\r\n", "")

      # @test_throws HTTP.ParsingError HTTP.parse(HTTP.Request, "GET / HTTP/1.1\r\nHost: www.example.com\r\nConnection\r\033\065\325eep-Alive\r\nAccept-Encoding: gzip\r\n\r\n")

      r = Request("GET /bad_get_no_headers_no_body/world HTTP/1.1\r\nAccept: */*\r\n\r\nHELLO")
      @test String(r.body) == ""
  end
end # @testset HTTP.parse

end # module ParserTest
