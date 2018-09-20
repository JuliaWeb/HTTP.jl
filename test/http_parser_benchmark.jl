# Based on HttpParser.jl/test/runtests.jl

module HttpParserTest

using HttpParser
using Test
using Compat
import Compat: String

headers = Dict()

function on_message_begin(parser)
    return 0
end

function on_url(parser, at, len)
    return 0
end

function on_status_complete(parser)
    return 0
end

function on_header_field(parser, at, len)
    header = unsafe_string(convert(Ptr{UInt8}, at), Int(len))
    # set the current header
    headers["current_header"] = header
    return 0
end

function on_header_value(parser, at, len)
    s = unsafe_string(convert(Ptr{UInt8}, at), Int(len))
    # once we know we have the header value, that will be the value for current header
    headers[headers["current_header"]] = s
    # reset current_header
    headers["current_header"] = ""
    return 0
end

function on_headers_complete(parser)
    p = unsafe_load(parser)
    # get first two bits of p.type_and_flags

    # The parser type are the bottom two bits
    # 0x03 = 00000011
    ptype = p.type_and_flags & 0x03
    # flags = p.type_and_flags >>> 3
    if ptype == 0
        method = http_method_str(convert(Int, p.method))
    end
    if ptype == 1
        headers["status_code"] = string(convert(Int, p.status_code))
    end
    headers["http_major"] = string(convert(Int, p.http_major))
    headers["http_minor"] = string(convert(Int, p.http_minor))
    headers["Keep-Alive"] = string(http_should_keep_alive(parser))
    return 0
end

function on_body(parser, at, len)
    return 0
end

function on_message_complete(parser)
    return 0
end

function on_chunk_header(parser)
    return 0
end

function on_chunk_complete(parser)
    return 0
end

c_message_begin_cb = cfunction(on_message_begin, HttpParser.HTTP_CB...)
c_url_cb = cfunction(on_url, HttpParser.HTTP_DATA_CB...)
c_status_complete_cb = cfunction(on_status_complete, HttpParser.HTTP_CB...)
c_header_field_cb = cfunction(on_header_field, HttpParser.HTTP_DATA_CB...)
c_header_value_cb = cfunction(on_header_value, HttpParser.HTTP_DATA_CB...)
c_headers_complete_cb = cfunction(on_headers_complete, HttpParser.HTTP_CB...)
c_body_cb = cfunction(on_body, HttpParser.HTTP_DATA_CB...)
c_message_complete_cb = cfunction(on_message_complete, HttpParser.HTTP_CB...)
c_body_cb = cfunction(on_body, HttpParser.HTTP_DATA_CB...)
c_message_complete_cb = cfunction(on_message_complete, HttpParser.HTTP_CB...)
c_chunk_header_cb = cfunction(on_chunk_header, HttpParser.HTTP_CB...)
c_chunk_complete_cb = cfunction(on_chunk_complete, HttpParser.HTTP_CB...)

function parse(bytes)
    # reset request
    # Moved this up for testing purposes
    global headers = Dict()
    parser = Parser()
    http_parser_init(parser, false)
    settings = ParserSettings(c_message_begin_cb, c_url_cb,
                              c_status_complete_cb, c_header_field_cb,
                              c_header_value_cb, c_headers_complete_cb,
                              c_body_cb, c_message_complete_cb,
                              c_chunk_header_cb, c_chunk_complete_cb)

    size = http_parser_execute(parser, settings, bytes)

    return headers
end



end
