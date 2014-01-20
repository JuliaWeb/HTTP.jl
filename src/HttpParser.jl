# Julian C bindings for Joyent's http-parser library.
# see: https://github.com/joyent/http-parser
#
include("../deps/ext.jl")
module HttpParser

using HttpCommon

import Base.show

# Export the structs and the C calls.
export Parser, 
       ParserSettings, 
       http_parser_init, 
       http_parser_execute, 
       http_method_str, 
       http_should_keep_alive,
       upgrade

# The shared C library name.
const lib = :libhttp_parser

# The id pool is used to keep track of incoming requests.
id_pool = 0

# A composite type that matches bit-for-bit a C struct.
type Parser
    # parser + flag = Single byte
    type_and_flags::Cuchar

    state::Cuchar
    header_state::Cuchar
    index::Cuchar

    nread::Uint32
    content_length::Uint64

    http_major::Cushort
    http_minor::Cushort
    status_code::Cushort
    method::Cuchar

    # http_errno + upgrade = Single byte
    errno_and_upgrade::Cuchar

    data::Any
    id::Int
end
Parser() = Parser(
    convert(Cuchar, 0),
    convert(Cuchar, 0),
    convert(Cuchar, 0),
    convert(Cuchar, 0),

    convert(Uint32, 0),
    convert(Uint64, 0),

    convert(Cushort, 0),
    convert(Cushort, 0),
    convert(Cushort, 0),
    convert(Cuchar, 0),

    convert(Cuchar, 0),

    convert(Ptr{Uint8}, Array(Int, 0)),
    (global id_pool += 1)
)

# A composite type that is expecting C functions to be run as callbacks.
type ParserSettings
    on_message_begin_cb::Ptr{None}
    on_url_cb::Ptr{None}
    on_status_complete_cb::Ptr{None}
    on_header_field_cb::Ptr{None}
    on_header_value_cb::Ptr{None}
    on_headers_complete_cb::Ptr{None}
    on_body_cb::Ptr{None}
    on_message_complete_cb::Ptr{None}
end

function show(io::IO,p::Parser)
    print(io,"HttpParser")
end

# A helper function to print the internal values of a request
function show(io::IO,r::Request)
    println(io,"=== Resource ====")
    println(io,"resource: $(r.resource)")
    println(io,"method: $(r.method)")
    println(io,"Headers:")
    for i=r.headers
        k = i[1]
        v = i[2]
        println(io,"    $k: $v")
    end
    println(io,"data: $(r.data)")
    println(io,"=== End Resource ===")
end

# Intializes the Parser object with the correct memory.
function http_parser_init(parser::Parser,isserver=true)
    ccall((:http_parser_init, lib), Void, (Ptr{Parser}, Cint), &parser, !isserver)
end

# Run a request through a parser with specific callbacks on the settings instance.
function http_parser_execute(parser::Parser, settings::ParserSettings, request::String)
    ccall((:http_parser_execute, lib), Csize_t, 
            (Ptr{Parser}, Ptr{ParserSettings}, Ptr{Uint8}, Csize_t,), 
            &parser, &settings, convert(Ptr{Uint8}, request), sizeof(request))
    if errno(parser) != 0
        throw(HttpParserError(errno(parser)))
    end
end

# Return a String representation of a given an HTTP method.
function http_method_str(method::Int)
    val = ccall((:http_method_str, lib), Ptr{Uint8}, (Int,), method)
    return bytestring(val)
end

# Is the request a keep-alive request?
function http_should_keep_alive(parser::Ptr{Parser})
    ccall((:http_should_keep_alive, lib), Int, (Ptr{Parser},), parser)
end
upgrade(p::Parser) = (p.errno_and_upgrade & 0b10000000)>0
errno(p::Parser) = p.errno_and_upgrade & 0b01111111
errno_name(errno::Integer) = bytestring(ccall((:http_errno_name,lib),Ptr{Uint8},(Int32,),errno))
errno_description(errno::Integer) = bytestring(ccall((:http_errno_description,lib),Ptr{Uint8},(Int32,),errno))

immutable HttpParserError <: Exception
    errno::Int32
    HttpParserError(errno::Integer) = new(int32(errno))
end

show(io::IO, err::HttpParserError) = print(io,"HTTP Parser Exception: ",errno_name(err.errno),"(",string(err.errno),"):",errno_description(err.errno))

end # module HttpParser
