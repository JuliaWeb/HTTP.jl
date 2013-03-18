module ParserTest

# This file runs a few tests and acts as an example of how to use the http-parser callbacks

include("HttpParser.jl")
using HttpParser

FIREFOX_REQ = tuple("GET /favicon.ico HTTP/1.1\r\n",
         "Host: 0.0.0.0=5000\r\n",
         "User-Agent: Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9) Gecko/2008061015 Firefox/3.0\r\n",
         "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n",
         "Accept-Language: en-us,en;q=0.5\r\n",
         "Accept-Encoding: gzip,deflate\r\n",
         "Accept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.7\r\n",
         "Keep-Alive: 300\r\n",
         "Connection: keep-alive\r\n",
         "\r\n")

DUMBFUCK = tuple("GET /dumbfuck HTTP/1.1\r\n",
         "aaaaaaaaaaaaa:++++++++++\r\n",
         "\r\n")

TWO_CHUNKS_MULT_ZERO_END = tuple("POST /two_chunks_mult_zero_end HTTP/1.1\r\n",
         "Transfer-Encoding: chunked\r\n",
         "\r\n",
         "5\r\nhello\r\n",
         "6\r\n world\r\n",
         "000\r\n",
         "\r\n")

WEBSOCK = tuple("DELETE /chat HTTP/1.1\r\n",
        "Host: server.example.com\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n",
        "Origin: http://example.com\r\n",
        "Sec-WebSocket-Protocol: chat, superchat\r\n",
        "Sec-WebSocket-Version: 13\r\n",
        "\r\n",)

r = HttpParser.Request("", "", Dict{String,String}(), "")

function on_message_begin(parser)
    # Clear the resource when the message starts
    r.resource = ""
    return 0     
end     

function on_url(parser, at, len)
    # Concatenate the resource for each on_url callback
    r.resource = string(r.resource, bytestring(convert(Ptr{Uint8}, at), int(len)))
    return 0
end

function on_status_complete(parser)
    return 0
end

function on_header_field(parser, at, len)
    header = bytestring(convert(Ptr{Uint8}, at), int(len))
    # set the current header
    r.headers["current_header"] = header
    return 0
end

function on_header_value(parser, at, len)
    s = bytestring(convert(Ptr{Uint8}, at), int(len))
    # once we know we have the header value, that will be the value for current header
    r.headers[r.headers["current_header"]] = s
    # reset current_header
    r.headers["current_header"] = ""
    return 0
end

function on_headers_complete(parser)
    p = unsafe_ref(parser)
    # get first two bits of p.type_and_flags
    
    # The parser type are the bottom two bits
    # 0x03 = 00000011
    ptype = p.type_and_flags & 0x03
    # flags = p.type_and_flags >>> 3
    if ptype == 0
        r.method = http_method_str(convert(Int, p.method))
    end
    if ptype == 1
        r.headers["status_code"] = string(convert(Int, p.status_code))
    end
    r.headers["http_major"] = string(convert(Int, p.http_major))
    r.headers["http_minor"] = string(convert(Int, p.http_minor))
    r.headers["Keep-Alive"] = string(http_should_keep_alive(parser))
    return 0
end

function on_body(parser, at, len)
    r.data = string(r.data, bytestring(convert(Ptr{Uint8}, at)), int(len))
    return 0
end

function on_message_complete(parser)
    return 0
end

c_message_begin_cb = cfunction(on_message_begin, Int, (Ptr{Parser},))
c_url_cb = cfunction(on_url, Int, (Ptr{Parser}, Ptr{Cchar}, Csize_t,))
c_status_complete_cb = cfunction(on_status_complete, Int, (Ptr{Parser},))
c_header_field_cb = cfunction(on_header_field, Int, (Ptr{Parser}, Ptr{Cchar}, Csize_t,))
c_header_value_cb = cfunction(on_header_value, Int, (Ptr{Parser}, Ptr{Cchar}, Csize_t,))
c_headers_complete_cb = cfunction(on_headers_complete, Int, (Ptr{Parser},))
c_body_cb = cfunction(on_body, Int, (Ptr{Parser}, Ptr{Cchar}, Csize_t,))
c_message_complete_cb = cfunction(on_message_complete, Int, (Ptr{Parser},))

function init(test::Tuple)
    # reset request
    # Moved this up for testing purposes
    r.method = ""
    r.resource = ""
    r.headers = Dict{String, String}()
    r.data = ""
    parser = Parser()
    http_parser_init(parser)
    settings = ParserSettings(c_message_begin_cb, c_url_cb, c_status_complete_cb, c_header_field_cb, c_header_value_cb, c_headers_complete_cb, c_body_cb, c_message_complete_cb)

    for i=1:length(test)
        size = http_parser_execute(parser, settings, test[i])
    end
    # errno = parser.errno_and_upgrade & 0xf3
    # upgrade = parser.errno_and_upgrade >>> 7
end

init(FIREFOX_REQ)
assert(r.method == "GET")
assert(r.resource == "/favicon.ico")
assert(r.headers["Host"] == "0.0.0.0=5000")
assert(r.headers["User-Agent"] == "Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9) Gecko/2008061015 Firefox/3.0")
assert(r.headers["Accept"] == "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
assert(r.headers["Accept-Language"] == "en-us,en;q=0.5")
assert(r.headers["Accept-Encoding"] == "gzip,deflate")
assert(r.headers["Accept-Charset"] == "ISO-8859-1,utf-8;q=0.7,*;q=0.7")
assert(r.headers["Keep-Alive"] == "1")
assert(r.headers["Connection"] == "keep-alive")
assert(r.data == "")
init(DUMBFUCK)
assert(r.method == "GET")
assert(r.resource == "/dumbfuck")
init(TWO_CHUNKS_MULT_ZERO_END)
assert(r.method == "POST")
assert(r.resource == "/two_chunks_mult_zero_end")
assert(r.data == "hello\r\n5 world\r\n6")
init(WEBSOCK)
assert(r.method == "DELETE")
assert(r.resource == "/chat")
println("All assertions passed!")
end

