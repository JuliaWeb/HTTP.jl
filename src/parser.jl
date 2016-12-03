const libhttp_parser = "libhttp_parser"

parsertype(::Type{Request}) = 0 # HTTP_REQUEST
parsertype(::Type{Response}) = 1 # HTTP_RESPONSE

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
end

parserwrapper(::Type{Request}) = ParserRequest()
parserwrapper(::Type{Response}) = ParserResponse()

function Parser{T}(::Type{T}=Request)
    parser = Parser(convert(Cuchar, 0), convert(Cuchar, 0), convert(Cuchar, 0), convert(Cuchar, 0),
                    convert(UInt32, 0), convert(UInt64, 0),
                    convert(Cushort, 0), convert(Cushort, 0), convert(Cushort, 0), convert(Cuchar, 0),
                    convert(Cuchar, 0),
                    convert(Ptr{UInt8}, C_NULL))
    parser.data = parserwrapper(T)
    http_parser_init(parser, T)
    return parser
end

# Intializes the Parser object with the correct memory
function http_parser_init{T}(parser, ::Type{T})
    ccall((:http_parser_init, libhttp_parser), Void, (Ptr{Parser}, Cint), &parser, parsertype(T))
end

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

ParserSettings(on_message_begin_cb, on_url_cb, on_status_complete_cb, on_header_field_cb, on_header_value_cb, on_headers_complete_cb, on_body_cb, on_message_complete_cb) =
    ParserSettings(on_message_begin_cb, on_url_cb, on_status_complete_cb, on_header_field_cb, on_header_value_cb, on_headers_complete_cb, on_body_cb, on_message_complete_cb, C_NULL, C_NULL)

function Base.show(io::IO, p::Parser)
    print(io,"libhttp-parser: v$(version()), ")
    print(io,"HTTP/$(p.http_major).$(p.http_minor), ")
    print(io,"Content-Length: $(p.content_length)")
end

function version()
    ver = ccall((:http_parser_version, libhttp_parser), Culong, ())
    major = (ver >> 16) & 255
    minor = (ver >> 8) & 255
    patch = ver & 255
    return VersionNumber(major, minor, patch)
end

# Run a request through a parser with specific callbacks on the settings instance
function http_parser_execute(parser::Parser, settings::ParserSettings, request, len=sizeof(request))
    return ccall((:http_parser_execute, libhttp_parser), Csize_t,
           (Ptr{Parser}, Ptr{ParserSettings}, Cstring, Csize_t,),
            Ref(parser), Ref(settings), convert(Cstring, pointer(request)), len)
end

"Returns a string version of the HTTP method."
function http_method_str(method)
    val = ccall((:http_method_str, libhttp_parser), Cstring, (Int,), method)
    return unsafe_string(val)
end

# Is the request a keep-alive request?
http_should_keep_alive(parser::Ptr{Parser}) = ccall((:http_should_keep_alive, libhttp_parser), Int, (Ptr{Parser},), Ref(parser)) != 0

"Pauses the parser."
pause(parser::Parser) = ccall((:http_parser_pause, libhttp_parser), Void, (Ptr{Parser}, Cint), Ref(parser), one(Cint))
"Resumes the parser."
resume(parser::Parser) = ccall((:http_parser_pause, libhttp_parser), Void,(Ptr{Parser}, Cint), Ref(parser), zero(Cint))
"Checks if this is the final chunk of the body."
isfinalchunk(parser::Parser) = ccall((:http_parser_pause, libhttp_parser), Cint, (Ptr{Parser},), Ref(parser)) == 1

upgrade(parser::Parser) = (parser.errno_and_upgrade & 0b10000000) > 0
errno(parser::Parser) = parser.errno_and_upgrade & 0b01111111
errno_name(errno::Integer) = unsafe_string(ccall((:http_errno_name, libhttp_parser), Cstring, (Int32,), errno))
errno_description(errno::Integer) = unsafe_string(ccall((:http_errno_description, libhttp_parser), Cstring, (Int32,), errno))

immutable ParserError <: Exception
    errno::Int32
    ParserError(errno::Integer) = new(Int32(errno))
end

Base.show(io::IO, err::ParserError) = print(io, "HTTP.ParserError: ", errno_name(err.errno), " (", err.errno, "): ", errno_description(err.errno))

# Dedicated types for parsing Request/Response types
type ParserRequest
    val::Request
    parsedfield::Bool
    fieldbuffer::Vector{UInt8}
    valuebuffer::Vector{UInt8}
    messagecomplete::Bool
end

ParserRequest() = ParserRequest(Request(), true, UInt8[], UInt8[], false)

type ParserResponse
    val::Response
    parsedfield::Bool
    fieldbuffer::Vector{UInt8}
    valuebuffer::Vector{UInt8}
    messagecomplete::Bool
end

ParserResponse() = ParserResponse(Response(), true, UInt8[], UInt8[], false)

# Default callbacks for requests and responses
getrequest(p::Ptr{Parser}) = (unsafe_load(p).data)::ParserRequest
getresponse(p::Ptr{Parser}) = (unsafe_load(p).data)::ParserResponse

# on_message_begin
function request_on_message_begin(parser)
    r = getrequest(parser)
    r.messagecomplete = false
    return 0
end

function response_on_message_begin(parser)
    r = getresponse(parser)
    r.messagecomplete = false
    return 0
end

# on_url (requests only)
function request_on_url(parser, at, len)
    r = getrequest(parser)
    r.val.resource = string(r.val.resource, unsafe_string(convert(Ptr{UInt8}, at), len))
    r.val.uri = URI(r.val.resource)
    return 0
end
response_on_url(parser, at, len) = 0

# on_status_complete (responses only)
function response_on_status_complete(parser)
    r = getresponse(parser)
    r.val.status = unsafe_load(parser).status_code
    return 0
end
request_on_status_complete(parser) = 0

# on_header_field, on_header_value
function request_on_header_field(parser, at, len)
    r = getrequest(parser)
    if r.parsedfield
        append!(r.fieldbuffer, unsafe_wrap(Array, convert(Ptr{UInt8}, at), len))
    else
        r.val.headers[String(r.fieldbuffer)] = String(r.valuebuffer)
        r.fieldbuffer = unsafe_wrap(Array, convert(Ptr{UInt8}, at), len)
    end
    r.parsedfield = true
    return 0
end

function request_on_header_value(parser, at, len)
    r = getrequest(parser)
    if r.parsedfield
        r.valuebuffer = unsafe_wrap(Array, convert(Ptr{UInt8}, at), len)
    else
        append!(r.valuebuffer, unsafe_wrap(Array, convert(Ptr{UInt8}, at), len))
    end
    r.parsedfield = false
    return 0
end

function response_on_header_field(parser, at, len)
    r = getresponse(parser)
    if r.parsedfield
        append!(r.fieldbuffer, unsafe_wrap(Array, convert(Ptr{UInt8}, at), len))
    else
        r.val.headers[String(r.fieldbuffer)] = String(r.valuebuffer)
        r.fieldbuffer = unsafe_wrap(Array, convert(Ptr{UInt8}, at), len)
    end
    r.parsedfield = true
    return 0
end

function response_on_header_value(parser, at, len)
    r = getresponse(parser)
    if r.parsedfield
        r.valuebuffer = unsafe_wrap(Array, convert(Ptr{UInt8}, at), len)
    else
        append!(r.valuebuffer, unsafe_wrap(Array, convert(Ptr{UInt8}, at), len))
    end
    r.parsedfield = false
    return 0
end

# on_headers_complete
function request_on_headers_complete(parser)
    r = getrequest(parser)
    p = unsafe_load(parser)
    if length(r.fieldbuffer) > 0
        r.val.headers[String(r.fieldbuffer)] = String(r.valuebuffer)
    end
    r.val.method = http_method_str(p.method)
    r.val.major = p.http_major
    r.val.minor = p.http_minor
    r.val.keepalive = http_should_keep_alive(parser) != 0
    return 0
end

function response_on_headers_complete(parser)
    r = getresponse(parser)
    p = unsafe_load(parser)
    if length(r.fieldbuffer) > 0
        r.val.headers[String(r.fieldbuffer)] = String(r.valuebuffer)
    end
    r.val.status = p.status_code
    r.val.major = p.http_major
    r.val.minor = p.http_minor
    return 0
end

# on_body
function on_body(parser, at, len)
    append!(unsafe_load(parser).data.val.data, unsafe_wrap(Array, convert(Ptr{UInt8}, at), len))
    return 0
end

# on_message_complete
function request_on_message_complete(parser)
    r = getrequest(parser)
    r.messagecomplete = true
    return 0
end

function response_on_message_complete(parser)
    r = getresponse(parser)
    r.messagecomplete = true
    return 0
end

# Main user-facing functions
function parse(::Type{Request}, str)
    http_parser_init(DEFAULT_REQUEST_PARSER, Request)
    http_parser_execute(DEFAULT_REQUEST_PARSER, DEFAULT_REQUEST_PARSER_SETTINGS, str, sizeof(str))
    if errno(DEFAULT_REQUEST_PARSER) != 0
        throw(ParserError(errno(DEFAULT_REQUEST_PARSER)))
    end
    return (DEFAULT_REQUEST_PARSER.data.val)::Request
end

function parse(::Type{Response}, str)
    http_parser_init(DEFAULT_REQUEST_PARSER, Response)
    http_parser_execute(DEFAULT_RESPONSE_PARSER, DEFAULT_RESPONSE_PARSER_SETTINGS, str, sizeof(str))
    if errno(DEFAULT_RESPONSE_PARSER) != 0
        throw(ParserError(errno(DEFAULT_RESPONSE_PARSER)))
    end
    return (DEFAULT_RESPONSE_PARSER.data.val)::Response
end

function __init__parser()
    HTTP_CB      = (Int, (Ptr{Parser},))
    HTTP_DATA_CB = (Int, (Ptr{Parser}, Ptr{Cchar}, Csize_t,))
    # Turn all the callbacks into C callable functions.
    global const request_on_message_begin_cb = cfunction(request_on_message_begin, HTTP_CB...)
    global const request_on_url_cb = cfunction(request_on_url, HTTP_DATA_CB...)
    global const request_on_status_complete_cb = cfunction(request_on_status_complete, HTTP_CB...)
    global const request_on_header_field_cb = cfunction(request_on_header_field, HTTP_DATA_CB...)
    global const request_on_header_value_cb = cfunction(request_on_header_value, HTTP_DATA_CB...)
    global const request_on_headers_complete_cb = cfunction(request_on_headers_complete, HTTP_CB...)
    global const on_body_cb = cfunction(on_body, HTTP_DATA_CB...)
    global const request_on_message_complete_cb = cfunction(request_on_message_complete, HTTP_CB...)
    global const DEFAULT_REQUEST_PARSER_SETTINGS = ParserSettings(request_on_message_begin_cb, request_on_url_cb,
                                                                  request_on_status_complete_cb, request_on_header_field_cb,
                                                                  request_on_header_value_cb, request_on_headers_complete_cb,
                                                                  on_body_cb, request_on_message_complete_cb)
    global const response_on_message_begin_cb = cfunction(response_on_message_begin, HTTP_CB...)
    global const response_on_url_cb = cfunction(response_on_url, HTTP_DATA_CB...)
    global const response_on_status_complete_cb = cfunction(response_on_status_complete, HTTP_CB...)
    global const response_on_header_field_cb = cfunction(response_on_header_field, HTTP_DATA_CB...)
    global const response_on_header_value_cb = cfunction(response_on_header_value, HTTP_DATA_CB...)
    global const response_on_headers_complete_cb = cfunction(response_on_headers_complete, HTTP_CB...)
    global const response_on_message_complete_cb = cfunction(response_on_message_complete, HTTP_CB...)
    global const DEFAULT_RESPONSE_PARSER_SETTINGS = ParserSettings(response_on_message_begin_cb, response_on_url_cb,
                                                                   response_on_status_complete_cb, response_on_header_field_cb,
                                                                   response_on_header_value_cb, response_on_headers_complete_cb,
                                                                   on_body_cb, response_on_message_complete_cb)
    #
    global const DEFAULT_REQUEST_PARSER = Parser(Request)
    global const DEFAULT_RESPONSE_PARSER = Parser(Response)
    return
end
