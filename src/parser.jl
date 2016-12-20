const libhttp_parser = "libhttp_parser"

parsertype(::Type{Request}) = 0 # HTTP_REQUEST
parsertype(::Type{Response}) = 1 # HTTP_RESPONSE

# A composite type that matches bit-for-bit a C struct.
type Parser{R}
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

    data::R # a RequestParser or ResponseParser
end

parserwrapper(::Type{Request}) = RequestParser()
parserwrapper(::Type{Response}) = ResponseParser()

function Parser{T}(::Type{T}=Request)
    parser = Parser(convert(Cuchar, 0), convert(Cuchar, 0), convert(Cuchar, 0), convert(Cuchar, 0),
                    convert(UInt32, 0), convert(UInt64, 0),
                    convert(Cushort, 0), convert(Cushort, 0), convert(Cushort, 0), convert(Cuchar, 0),
                    convert(Cuchar, 0),
                    parserwrapper(T))
    http_parser_init(parser, T)
    return parser
end

# Intializes the Parser object with the correct memory
function http_parser_init{R, T}(parser::Parser{R}, ::Type{T})
    ccall((:http_parser_init, libhttp_parser), Void, (Ptr{Parser{R}}, Cint), Ref(parser), parsertype(T))
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

function Base.show{R}(io::IO, p::Parser{R})
    print(io,"$(typeof(p)): v$(version()), ")
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
function http_parser_execute{R}(parser::Parser{R}, settings::ParserSettings, request, len=sizeof(request))
    return ccall((:http_parser_execute, libhttp_parser), Csize_t,
           (Ptr{Parser{R}}, Ptr{ParserSettings}, Cstring, Csize_t,),
            Ref(parser), Ref(settings), convert(Cstring, pointer(request)), len)
end

"Returns a string version of the HTTP method."
function http_method_str(method)
    val = ccall((:http_method_str, libhttp_parser), Cstring, (Int,), method)
    return unsafe_string(val)
end

# Is the request a keep-alive request?
http_should_keep_alive{R}(parser::Ptr{Parser{R}}) = ccall((:http_should_keep_alive, libhttp_parser), Int, (Ptr{Parser{R}},), Ref(parser)) != 0

"Pauses the parser."
pause{R}(parser::Parser{R}) = ccall((:http_parser_pause, libhttp_parser), Void, (Ptr{Parser{R}}, Cint), Ref(parser), one(Cint))
"Resumes the parser."
resume{R}(parser::Parser{R}) = ccall((:http_parser_pause, libhttp_parser), Void,(Ptr{Parser{R}}, Cint), Ref(parser), zero(Cint))
"Checks if this is the final chunk of the body."
isfinalchunk{R}(parser::Parser{R}) = ccall((:http_parser_pause, libhttp_parser), Cint, (Ptr{Parser{R}},), Ref(parser)) == 1

upgrade{R}(parser::Parser{R}) = (parser.errno_and_upgrade & 0b10000000) > 0
errno{R}(parser::Parser{R}) = parser.errno_and_upgrade & 0b01111111
errno_name(errno::Integer) = unsafe_string(ccall((:http_errno_name, libhttp_parser), Cstring, (Int32,), errno))
errno_description(errno::Integer) = unsafe_string(ccall((:http_errno_description, libhttp_parser), Cstring, (Int32,), errno))

immutable ParserError <: Exception
    errno::Int32
    ParserError(errno::Integer) = new(Int32(errno))
end

Base.show(io::IO, err::ParserError) = print(io, "HTTP.ParserError: ", errno_name(err.errno), " (", err.errno, "): ", errno_description(err.errno))

# Dedicated types for parsing Request/Response types
type RequestParser
    val::Request
    parsedfield::Bool
    fieldbuffer::String
    valuebuffer::String
    messagecomplete::Bool
    headerscomplete::Bool
    task::Task
    cookies::Vector{String}
end

RequestParser() = RequestParser(Request(), true, "", "", false, false, current_task(), String[])

type ResponseParser
    val::Response
    parsedfield::Bool
    fieldbuffer::String
    valuebuffer::String
    messagecomplete::Bool
    headerscomplete::Bool
    task::Task
    cookies::Vector{String}
end

ResponseParser() = ResponseParser(Response(), true, "", "", false, false, current_task(), String[])

function reset!(r)
    r.parsedfield = true
    r.fieldbuffer = ""
    r.valuebuffer = ""
    r.messagecomplete = r.headerscomplete = false
    empty!(r.cookies)
    return
end

# Default callbacks for requests and responses
unload{R}(p::Ptr{Parser{R}}) = (unsafe_load(p).data)::R

# on_message_begin
function request_on_message_begin(parser::Ptr{Parser{RequestParser}})
    r = unload(parser)
    reset!(r)
    return 0
end

function response_on_message_begin(parser::Ptr{Parser{ResponseParser}})
    r = unload(parser)
    reset!(r)
    return 0
end

# on_url (requests only)
function request_on_url(parser::Ptr{Parser{RequestParser}}, at, len)
    r = unload(parser)
    r.val.uri = URI(str(at, len))
    return 0
end
response_on_url(parser, at, len) = 0

# on_status_complete (responses only)
function response_on_status_complete(parser::Ptr{Parser{ResponseParser}})
    r = unload(parser)
    r.val.status = unsafe_load(parser).status_code
    return 0
end
request_on_status_complete(parser) = 0

str(at, len) = unsafe_string(convert(Ptr{UInt8}, at), len)

# on_header_field, on_header_value
function request_on_header_field(parser::Ptr{Parser{RequestParser}}, at, len)
    r = unload(parser)
    if r.parsedfield
        r.fieldbuffer *= str(at, len)
    else
        r.val.headers[r.fieldbuffer] = r.valuebuffer
        r.fieldbuffer = str(at, len)
    end
    r.parsedfield = true
    return 0
end

function request_on_header_value(parser::Ptr{Parser{RequestParser}}, at, len)
    r = unload(parser)
    s = str(at, len)
    r.valuebuffer = ifelse(r.parsedfield, s, r.valuebuffer * s)
    r.parsedfield = false
    return 0
end

macro eq(b, c)
    return esc(:(($b == $c || $b == $(uppercase(c)))))
end

function issetcookie(bytes)
    length(bytes) == 10 || return false
    @inbounds begin
    @eq(bytes[1], 's') || return false
    @eq(bytes[2], 'e') || return false
    @eq(bytes[3], 't') || return false
    bytes[4] == '-' || return false
    @eq(bytes[5], 'c') || return false
    @eq(bytes[6], 'o') || return false
    @eq(bytes[7], 'o') || return false
    @eq(bytes[8], 'k') || return false
    @eq(bytes[9], 'i') || return false
    @eq(bytes[10], 'e') || return false
    end
    return true
end

function response_on_header_field(parser::Ptr{Parser{ResponseParser}}, at, len)
    r = unload(parser)
    if r.parsedfield
        r.fieldbuffer *= str(at, len)
    else
        issetcookie(r.fieldbuffer) && push!(r.cookies, r.valuebuffer)
        r.val.headers[r.fieldbuffer] = get!(r.val.headers, r.fieldbuffer, "") * r.valuebuffer
        r.fieldbuffer = str(at, len)
    end
    r.parsedfield = true
    return 0
end

function response_on_header_value(parser::Ptr{Parser{ResponseParser}}, at, len)
    r = unload(parser)
    s = str(at, len)
    r.valuebuffer = ifelse(r.parsedfield, s, r.valuebuffer * s)
    r.parsedfield = false
    return 0
end

# on_headers_complete
function request_on_headers_complete(parser::Ptr{Parser{RequestParser}})
    r = unload(parser)
    p = unsafe_load(parser)
    # store the last header key=>val
    if !isempty(r.fieldbuffer)
        r.val.headers[r.fieldbuffer] = r.valuebuffer
    end
    r.val.method = http_method_str(p.method)
    r.val.major = p.http_major
    r.val.minor = p.http_minor
    r.val.keepalive = http_should_keep_alive(parser) != 0
    r.headerscomplete = true
    return 0
end

function response_on_headers_complete(parser::Ptr{Parser{ResponseParser}})
    r = unload(parser)
    p = unsafe_load(parser)
    # store the last header key=>val
    issetcookie(r.fieldbuffer) && push!(r.cookies, r.valuebuffer)
    if !isempty(r.fieldbuffer)
        r.val.headers[r.fieldbuffer] = get!(r.val.headers, r.fieldbuffer, "") * r.valuebuffer
    end
    r.val.status = p.status_code
    r.val.major = p.http_major
    r.val.minor = p.http_minor
    r.val.keepalive = http_should_keep_alive(parser) != 0
    req = r.val.request
    host = isnull(req) ? "" : Base.get(req).uri.host
    r.val.cookies = Cookies.readsetcookies(host, r.cookies)
    r.headerscomplete = true
    # From https://github.com/nodejs/http-parser/blob/master/http_parser.h
    # Comment starting line 72
    # On a HEAD method return 1 instead of 0 to indicate that the parser
    # should not expect a body.
    method = isnull(req) ? "" : Base.get(req).method
    if method == "HEAD"
        r.messagecomplete = true
        return 1  # Signal HTTP parser to not expect a body
    elseif method == "CONNECT"
        r.messagecomplete = true
        return 2
    else
        return 0
    end
end

# on_body
output(r, body::IO, data) = (write(body, data); return nothing)
output(r, body::Vector{UInt8}, data) = (append!(body, data); return nothing)
output(r, body::String, data) = (r.val.body *= String(data); return nothing)
function output(r, body::IOBuffer, data)
    append!(body.data, data)
    body.size = length(body.data)
    return nothing
end

function output(r, body::FIFOBuffer, data)
    nb = write(body, data)
    println("outputting body..."); flush(STDOUT)
    if current_task() == r.task
        # main request function hasn't returned yet, so not safe to wait
        println("still in main task...growing FIFOBuffer...")
        body.max += length(data) - nb
        write(body, view(data, nb+1:length(data)))
    else
        while nb < length(data)
            println("waiting...")
            nb += write(body, data)
        end
    end
    println("wrote $nb bytes of data..."); flush(STDOUT)
    return nothing
end

function request_on_body(parser::Ptr{Parser{RequestParser}}, at, len)
    r = unsafe_load(parser).data
    output(r, r.val.body, unsafe_wrap(Array, convert(Ptr{UInt8}, at), len))
    return 0
end

function response_on_body(parser::Ptr{Parser{ResponseParser}}, at, len)
    r = unsafe_load(parser).data
    output(r, r.val.body, unsafe_wrap(Array, convert(Ptr{UInt8}, at), len))
    return 0
end

# on_message_complete
function request_on_message_complete(parser::Ptr{Parser{RequestParser}})
    r = unload(parser)
    r.messagecomplete = true
    return 0
end

function response_on_message_complete(parser::Ptr{Parser{ResponseParser}})
    r = unload(parser)
    r.messagecomplete = true
    println("messagecomplete...")
    eof!(r.val.body)
    return 0
end

# Main user-facing functions
"""
`HTTP.parse{R <: Union{Request, Response}}(::Type{R}, str)` => `R`

Given a string input `str`, use [`http-parser`](https://github.com/nodejs/http-parser) to create
and populate a Julia `Request` or `Response` object.
"""
function parse end

function parse(::Type{Request}, str)
    DEFAULT_REQUEST_PARSER.data.val = Request()
    http_parser_init(DEFAULT_REQUEST_PARSER, Request)
    http_parser_execute(DEFAULT_REQUEST_PARSER, DEFAULT_REQUEST_PARSER_SETTINGS, str, sizeof(str))
    if errno(DEFAULT_REQUEST_PARSER) != 0
        throw(ParserError(errno(DEFAULT_REQUEST_PARSER)))
    end
    return (DEFAULT_REQUEST_PARSER.data.val)::Request
end

function parse(::Type{Response}, str)
    DEFAULT_RESPONSE_PARSER.data.val = Response()
    http_parser_init(DEFAULT_RESPONSE_PARSER, Response)
    http_parser_execute(DEFAULT_RESPONSE_PARSER, DEFAULT_RESPONSE_PARSER_SETTINGS, str, sizeof(str))
    if errno(DEFAULT_RESPONSE_PARSER) != 0
        throw(ParserError(errno(DEFAULT_RESPONSE_PARSER)))
    end
    return (DEFAULT_RESPONSE_PARSER.data.val)::Response
end

function __init__parser()
    HTTP_REQUEST_CB      = (Int, (Ptr{Parser{RequestParser}},))
    HTTP_DATA_REQUEST_CB = (Int, (Ptr{Parser{RequestParser}}, Ptr{Cchar}, Csize_t,))
    HTTP_RESPONSE_CB      = (Int, (Ptr{Parser{ResponseParser}},))
    HTTP_DATA_RESPONSE_CB = (Int, (Ptr{Parser{ResponseParser}}, Ptr{Cchar}, Csize_t,))
    # Turn all the callbacks into C callable functions.
    global const request_on_message_begin_cb = cfunction(request_on_message_begin, HTTP_REQUEST_CB...)
    global const request_on_url_cb = cfunction(request_on_url, HTTP_DATA_REQUEST_CB...)
    global const request_on_status_complete_cb = cfunction(request_on_status_complete, HTTP_REQUEST_CB...)
    global const request_on_header_field_cb = cfunction(request_on_header_field, HTTP_DATA_REQUEST_CB...)
    global const request_on_header_value_cb = cfunction(request_on_header_value, HTTP_DATA_REQUEST_CB...)
    global const request_on_headers_complete_cb = cfunction(request_on_headers_complete, HTTP_REQUEST_CB...)
    global const request_on_body_cb = cfunction(request_on_body, HTTP_DATA_REQUEST_CB...)
    global const request_on_message_complete_cb = cfunction(request_on_message_complete, HTTP_REQUEST_CB...)
    global const DEFAULT_REQUEST_PARSER_SETTINGS = ParserSettings(request_on_message_begin_cb, request_on_url_cb,
                                                                  request_on_status_complete_cb, request_on_header_field_cb,
                                                                  request_on_header_value_cb, request_on_headers_complete_cb,
                                                                  request_on_body_cb, request_on_message_complete_cb)
    global const response_on_message_begin_cb = cfunction(response_on_message_begin, HTTP_RESPONSE_CB...)
    global const response_on_url_cb = cfunction(response_on_url, HTTP_DATA_RESPONSE_CB...)
    global const response_on_status_complete_cb = cfunction(response_on_status_complete, HTTP_RESPONSE_CB...)
    global const response_on_header_field_cb = cfunction(response_on_header_field, HTTP_DATA_RESPONSE_CB...)
    global const response_on_header_value_cb = cfunction(response_on_header_value, HTTP_DATA_RESPONSE_CB...)
    global const response_on_headers_complete_cb = cfunction(response_on_headers_complete, HTTP_RESPONSE_CB...)
    global const response_on_body_cb = cfunction(response_on_body, HTTP_DATA_RESPONSE_CB...)
    global const response_on_message_complete_cb = cfunction(response_on_message_complete, HTTP_RESPONSE_CB...)
    global const DEFAULT_RESPONSE_PARSER_SETTINGS = ParserSettings(response_on_message_begin_cb, response_on_url_cb,
                                                                   response_on_status_complete_cb, response_on_header_field_cb,
                                                                   response_on_header_value_cb, response_on_headers_complete_cb,
                                                                   response_on_body_cb, response_on_message_complete_cb)
    #
    global const DEFAULT_REQUEST_PARSER = Parser(Request)
    global const DEFAULT_RESPONSE_PARSER = Parser(Response)
    return
end
