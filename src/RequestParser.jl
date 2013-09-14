# `RequestParser` handles all the `HttpParser` module stuff for `Http`
#
# The `HttpParser` module wraps [Joyent's `http-parser` C library][hprepo]. 
# A new `HttpParser` is created for each TCP connection being handled by
# our server.  Each `HttpParser` is initialized with a set of callback
# functions. When new data comes in, it is fed into the `http-parser` which
# executes the callbacks as different elements are parsed.  Finally, it calls
# on_message_complete when the incoming `Request` is fully built. The parser
# does not care if it recieves just one byte at a time, or mulitple requests.
# It will simply parse in order and run the callbacks normally.
#
# Because Julia does not support calling closures from C, we have to store
# both the in-progress `Request` instances and the meat-and-potatoes part
# of the on_message_complete callbacks in the global Dicts `partials` and
# `message_complete_callbacks`.  Because the different callbacks are passed
# slightly different arguments from C, `partials` uses the `parser` pointer
# as a key, while `message_complete_callbacks` uses `parser.id`.  These must
# be manually garbage collected by calling `clean!` when closing connections.
#
# Note that this is not a module, it is included directly in `Http.jl`
#
# [hprepo]: https://github.com/joyent/http-parser
#
using HttpParser
using HttpCommon
export RequestParser,
       clean!,
       add_data

# Datatype Tuples for the different `cfunction` signatures used by `HttpParser`
HTTP_CB      = (Int, (Ptr{Parser},))
HTTP_DATA_CB = (Int, (Ptr{Parser}, Ptr{Cchar}, Csize_t,))

# All the `HttpParser` callbacks to be run in C land
# Each one adds data to the `Request` until it is complete
#
function on_message_begin(parser)
    pd(parser).request = Request()
    return 0
end

function on_url(parser, at, len)
    r = pd(parser).request
    r.resource = string(r.resource, bytestring(convert(Ptr{Uint8}, at),int(len)))
    return 0
end

function on_status_complete(parser)
    return 0
end

# Gather the header_field, set the field
# on header value, set the value for the current field
# there might be a better way to do 
# this: https://github.com/joyent/node/blob/master/src/node_http_parser.cc#L207

function on_header_field(parser, at, len)
    r = pd(parser).request
    header = bytestring(convert(Ptr{Uint8}, at))
    header_field = header[1:len]
    r.headers["current_header"] = header_field
    return 0
end

function on_header_value(parser, at, len)
    r = pd(parser).request
    s = bytestring(convert(Ptr{Uint8}, at),int(len))
    r.headers[r.headers["current_header"]] = s
    r.headers["current_header"] = ""
    return 0
end

function on_headers_complete(parser)
    r = pd(parser).request
    p = unsafe_load(parser)
    # get first two bits of p.type_and_flags
    ptype = p.type_and_flags & 0x03
    if ptype == 0
        r.method = http_method_str(convert(Int, p.method))
    elseif ptype == 1
        r.headers["status_code"] = string(convert(Int, p.status_code))
    end
    r.headers["http_major"] = string(convert(Int, p.http_major))
    r.headers["http_minor"] = string(convert(Int, p.http_minor))
    r.headers["Keep-Alive"] = string(http_should_keep_alive(parser))
    return 0
end

function on_body(parser, at, len)
    r = pd(parser).request
    write(pd(parser).data,bytestring(convert(Ptr{Uint8}, at)),len)
    return 0
end

function on_message_complete(parser)
    state = pd(parser)
    r = state.request
    r.data = takebuf_string(state.data)

    # delete the temporary header key
    pop!(r.headers, "current_header", nothing)

    # Get the `parser.id` from the C pointer `parser`.
    # Retrieve our callback function from the global Dict.
    # Call it with the completed `Request`
    #
    state.complete_cb(r)
    return 0
end

# Turn all the callbacks into C callable functions.
on_message_begin_cb = cfunction(on_message_begin, HTTP_CB...)
on_url_cb = cfunction(on_url, HTTP_DATA_CB...)
on_status_complete_cb = cfunction(on_status_complete, HTTP_CB...)
on_header_field_cb = cfunction(on_header_field, HTTP_DATA_CB...)
on_header_value_cb = cfunction(on_header_value, HTTP_DATA_CB...)
on_headers_complete_cb = cfunction(on_headers_complete, HTTP_CB...)
on_body_cb = cfunction(on_body, HTTP_DATA_CB...)
on_message_complete_cb = cfunction(on_message_complete, HTTP_CB...)

default_complete_cb(r::Request) = nothing

type RequestParserState
    request::Request
    data::IOBuffer
    complete_cb::Function
end
RequestParserState() = RequestParserState(Request(),IOBuffer(),default_complete_cb)

pd(p::Ptr{Parser}) = (unsafe_load(p).data)::RequestParserState

# `ClientParser` wraps our `HttpParser`
# Constructed with `on_message_complete` function.
#
immutable ClientParser
    parser::Parser
    settings::ParserSettings

    function ClientParser(on_message_complete::Function)
        parser = Parser()
        parser.data = RequestParserState()
        http_parser_init(parser)
        parser.data.complete_cb = on_message_complete

        settings = ParserSettings(on_message_begin_cb, on_url_cb,
                                  on_status_complete_cb, on_header_field_cb,
                                  on_header_value_cb, on_headers_complete_cb,
                                  on_body_cb, on_message_complete_cb)

        new(parser, settings)
    end
end

# Passes `request_data` into `parser`
function add_data(parser::ClientParser, request_data::String)
    http_parser_execute(parser.parser, parser.settings, request_data)
end
