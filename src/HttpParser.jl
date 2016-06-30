# Julian C bindings for Joyent's http-parser library.
# see: https://github.com/joyent/http-parser
#
isdefined(Base, :__precompile__) && __precompile__()

module HttpParser

depsjl = joinpath(dirname(@__FILE__), "..", "deps", "deps.jl")
isfile(depsjl) ? include(depsjl) : error("HttpParser not properly ",
    "installed. Please run\nPkg.build(\"HttpParser\")")

using HttpCommon
using Compat
import Compat: String

import Base.show

# Export the structs and the C calls.
export Parser,
       ParserSettings,
       http_parser_init,
       http_parser_execute,
       http_method_str,
       http_should_keep_alive,
       upgrade,
       parse_url

# The id pool is used to keep track of incoming requests.
id_pool = 0

# A composite type that matches bit-for-bit a C struct.
type Parser
    # parser + flag = Single byte
    type_and_flags::Cuchar

    state::Cuchar
    header_state::Cuchar
    index::Cuchar

    nread::UInt32
    content_length::UInt64

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

    convert(UInt32, 0),
    convert(UInt64, 0),

    convert(Cushort, 0),
    convert(Cushort, 0),
    convert(Cushort, 0),
    convert(Cuchar, 0),

    convert(Cuchar, 0),

    convert(Ptr{UInt8}, C_NULL),
    (global id_pool += 1)
)

# Datatype Tuples for the different `cfunction` signatures for callback functions
const HTTP_CB      = (Int, (Ptr{Parser},))
const HTTP_DATA_CB = (Int, (Ptr{Parser}, Ptr{Cchar}, Csize_t,))

# A composite type that is expecting C functions to be run as callbacks.
type ParserSettings
    on_message_begin_cb::Ptr{Void}
    on_url_cb::Ptr{Void}
    on_status_complete_cb::Ptr{Void}
    on_header_field_cb::Ptr{Void}
    on_header_value_cb::Ptr{Void}
    on_headers_complete_cb::Ptr{Void}
    on_body_cb::Ptr{Void}
    on_message_complete_cb::Ptr{Void}
    on_chunk_header::Ptr{Void}
    on_chunk_complete::Ptr{Void}
end

ParserSettings(on_message_begin_cb, on_url_cb, on_status_complete_cb, on_header_field_cb, on_header_value_cb, on_headers_complete_cb, on_body_cb, on_message_complete_cb) = ParserSettings(on_message_begin_cb, on_url_cb, on_status_complete_cb, on_header_field_cb, on_header_value_cb, on_headers_complete_cb, on_body_cb, on_message_complete_cb, C_NULL, C_NULL)

function show(io::IO,p::Parser)
    print(io,"libhttp-parser: v$(version()), ")
    print(io,"HTTP/$(p.http_major).$(p.http_minor), ")
    print(io,"Content-Length: $(p.content_length)")
end

function version()
    ver = ccall((:http_parser_version, lib), Culong, ())
    major = (ver >> 16) & 255
    minor = (ver >> 8) & 255
    patch = ver & 255
    return VersionNumber(major, minor, patch)
end

"Intializes the Parser object with the correct memory."
function http_parser_init(parser::Parser,isserver=true)
    ccall((:http_parser_init, lib), Void, (Ptr{Parser}, Cint), &parser, !isserver)
end

"Run a request through a parser with specific callbacks on the settings instance."
function http_parser_execute(parser::Parser, settings::ParserSettings, request)
    ccall((:http_parser_execute, lib), Csize_t,
           (Ptr{Parser}, Ptr{ParserSettings}, Cstring, Csize_t,),
            Ref(parser), Ref(settings), convert(Cstring, pointer(request)), sizeof(request))
    if errno(parser) != 0
        throw(HttpParserError(errno(parser)))
    end
end

"Returns a string version of the HTTP method."
function http_method_str(method::Int)
    val = ccall((:http_method_str, lib), Cstring, (Int,), method)
    return String(val)
end

# Is the request a keep-alive request?
function http_should_keep_alive(parser::Ptr{Parser})
    ccall((:http_should_keep_alive, lib), Int, (Ptr{Parser},), Ref(parser))
end

"Pauses the parser."
pause(parser::Parser) = ccall((:http_parser_pause,lib), Void, (Ptr{Parser}, Cint), Ref(parser), one(Cint))
"Resumes the parser."
resume(parser::Parser) = ccall((:http_parser_pause,lib), Void,(Ptr{Parser}, Cint), Ref(parser), zero(Cint))
"Checks if this is the final chunk of the body."
isfinalchunk(parser::Parser) = ccall((:http_parser_pause,lib), Cint, (Ptr{Parser},), Ref(parser)) == 1

upgrade(parser::Parser) = (parser.errno_and_upgrade & 0b10000000)>0
errno(parser::Parser) = parser.errno_and_upgrade & 0b01111111
errno_name(errno::Integer) = String(ccall((:http_errno_name,lib),Cstring,(Int32,),errno))
errno_description(errno::Integer) = String(ccall((:http_errno_description,lib),Cstring,(Int32,),errno))

immutable HttpParserError <: Exception
    errno::Int32
    HttpParserError(errno::Integer) = new(Int32(errno))
end

show(io::IO, err::HttpParserError) = print(io,"HTTP Parser Exception: ",errno_name(err.errno),"(",string(err.errno),"):",errno_description(err.errno))


@enum(UrlFields, UF_SCHEMA           = Cint(0),
                 UF_HOST             = Cint(1),
                 UF_PORT             = Cint(2),
                 UF_PATH             = Cint(3),
                 UF_QUERY            = Cint(4),
                 UF_FRAGMENT         = Cint(5),
                 UF_USERINFO         = Cint(6),
                 UF_MAX              = Cint(7))

immutable ParserUrl
    field_set::UInt16 # Bitmask of (1 << UF_*) values
    port::UInt16      # Converted UF_PORT string
    field_data::NTuple{Cint(UF_MAX)*2, UInt16}
    ParserUrl() = new(zero(UInt16), zero(UInt16), ntuple(i->zero(UInt16), Cint(UF_MAX)*2))
end

"Parse a URL"
function parse_url(url::AbstractString; isconnect::Bool = false)
    parsed = Dict{Symbol,AbstractString}()
    purl_ref = Ref(ParserUrl())
    res = ccall((:http_parser_parse_url, lib), Cint,
                 (Cstring, Csize_t, Cint, Ptr{ParserUrl}),
                  url, sizeof(url), Cint(isconnect), purl_ref)
    res > 0 && return parsed, -1
    purl = purl_ref[]

    for (i,uf) in enumerate(instances(UrlFields))
        !((purl.field_set & (1 << Cint(uf)) > 0) && uf != UF_MAX) && continue
        off = purl.field_data[2*(i-1)+1]
        len = purl.field_data[2*(i-1)+2]
        parsed[Symbol(uf)] = url[(off+1):(off+len)]
    end
    return parsed, purl.port
end


end # module HttpParser
