module HttpParser

export Parser, ParserSettings, http_parser_init, print, http_parser_execute, http_method_str, http_should_keep_alive

const lib = "libhttp_parser"

typealias Headers Dict{String,String}

type Request
    method::String
    resource::String
    headers::Headers
    data::String
end
Request(m::String, r::String, h::Headers) = Request(m, r, h, "")
Request(m::String, r::String, d::String)  = Request(m, r, Headers(), d)
Request(m::String, r::String)             = Request(m, r, Headers(), "")

type Parser
    # parser + flag = Single byte
    type_and_flags::Cuchar

    state::Cuchar
    header_state::Cuchar
    index::Cuchar

    nread::Cuint
    content_length::Culong

    http_major::Cushort
    http_minor::Cushort
    status_code::Cushort
    method::Cuchar

    # http_errno + upgrade = Single byte
    errno_and_upgrade::Cuchar

    data::Ptr{Uint8}
    id::Int
end

id_pool = 0

Parser() = Parser(
    convert(Cuchar, 0),
    convert(Cuchar, 0),
    convert(Cuchar, 0),
    convert(Cuchar, 0),

    convert(Cuint, 0),
    convert(Culong, 0),

    convert(Cushort, 0),
    convert(Cushort, 0),
    convert(Cushort, 0),
    convert(Cuchar, 0),

    convert(Cuchar, 0),

    convert(Ptr{Uint8}, Array(Int, 0)),
    (global id_pool += 1)
)

function http_parser_init(parser::Parser)
    ccall((:http_parser_init, lib), Void, (Ptr{Parser}, Cint), &parser, 0)
end

# Note: we really don't care about the parser. We just want to grab data from
# it in the callbacks and return a request/response object.
function print(r::Request)
    method = r.method
    resource = r.resource
    headers = r.headers
    data = r.data
    println("=== Resource ====")
    println("resource: $resource")
    println("method: $method")
    println("Headers:")
    for i=headers
        k = i[1]
        v = i[2]
        println("    $k: $v")
    end
    println("data: $data")
    println("=== End Resource ===")
end


# expecting C functions that set values from parser.data
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

function http_parser_execute(parser::Parser, settings::ParserSettings, request::String)
    ccall((:http_parser_execute, lib), Csize_t, 
            (Ptr{Parser}, Ptr{ParserSettings}, Ptr{Uint8}, Csize_t,), 
            &parser, &settings, convert(Ptr{Uint8}, request), length(request))
end

function http_method_str(method::Int)
    val = ccall((:http_method_str, lib), Ptr{Uint8}, (Int,), method)
    return bytestring(val)
end

function http_should_keep_alive(parser::Ptr{Parser})
    ccall((:http_should_keep_alive, lib), Int, (Ptr{Parser},), parser)
end

end # module HttpParser
