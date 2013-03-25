# `RequestParser` handles all the `HttpParser` module stuff for `Http.jl`
#
# The `HttpParser` module wraps [Joyent's `http-parser` C library][repo]. 
# A new `HttpParser` is created for each TCP connection being handled by
# our server.  Each `HttpParser` is initialized with a set of callback
# functions, When new data comes in, it is fed into the `http-parser` which
# calls
#
# Not a module, included directly in `Http.jl`
#
# [repo]: https://github.com/joyent/http-parser
#
using HttpParser
export RequestParser,
       clean!,
       add_data

# Datatype Tuples for the different `cfunction` signatures used by `HttpParser`
HTTP_CB      = (Int, (Ptr{Parser},))
HTTP_DATA_CB = (Int, (Ptr{Parser}, Ptr{Cchar}, Csize_t,))

import Httplib.Request
Request() = Request("", "", Httplib.headers(), "", Dict{Any, Any}())

# IMPORTANT!!! This requires manual memory management.
#
# Each Client needs its own PartialRequest. Since closures are not
# c-callable, we have to keep a global dictionary of Parser pointers
# to PartialRequests. Callbacks will lookup their partial in this
# global dict. Partials must be manually deleted when connections
# are closed or memory leaks will occur.
partials = Dict{Ptr{Parser}, Request}()
message_complete_callbacks = Dict{Int, Function}()

function on_message_begin(parser)
    partials[parser] = Request()
    return 0
end
on_message_begin_cb = cfunction(on_message_begin, HTTP_CB...)

function on_url(parser, at, len)
    r = partials[parser]
    r.resource = string(r.resource, bytestring(convert(Ptr{Uint8}, at),int(len)))
    return 0
end
on_url_cb = cfunction(on_url, HTTP_DATA_CB...)

function on_status_complete(parser)
    return 0
end
on_status_complete_cb = cfunction(on_status_complete, HTTP_CB...)

# Gather the header_field, set the field
# on header value, set the value for the current field
# there might be a better way than this: https://github.com/joyent/node/blob/master/src/node_http_parser.cc#L207

function on_header_field(parser, at, len)
    r = partials[parser]
    header = bytestring(convert(Ptr{Uint8}, at))
    header_field = header[1:len]
    r.headers["current_header"] = header_field
    return 0
end
on_header_field_cb = cfunction(on_header_field, HTTP_DATA_CB...)

function on_header_value(parser, at, len)
    r = partials[parser]
    s = bytestring(convert(Ptr{Uint8}, at),int(len))
    r.headers[r.headers["current_header"]] = s
    r.headers["current_header"] = ""
    return 0
end
on_header_value_cb = cfunction(on_header_value, HTTP_DATA_CB...)

function on_headers_complete(parser)
    r = partials[parser]
    p = unsafe_ref(parser)
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
on_headers_complete_cb = cfunction(on_headers_complete, HTTP_CB...)

function on_body(parser, at, len)
    r = partials[parser]
    r.data = string(r.data, bytestring(convert(Ptr{Uint8}, at)))
    return 0
end
on_body_cb = cfunction(on_body, HTTP_DATA_CB...)

function on_message_complete(parser)
    r = partials[parser]
    delete!(r.headers, "current_header", nothing)

    # Handle URL variables eg. `foo/bar?a=b&c=d`
    m = match(r"\?.*=.*", r.resource)
    url_params = (String => String)[]
    if m != nothing
        for set in split(split(r.resource, "?")[2], "&")
            key, val = split(set, "=")
            url_params[key] = val
        end
    end
    raw_resource = r.resource
    r.resource = split(r.resource,'?')[1]
    r.state[:raw_resource] = raw_resource
    r.state[:url_params]   = url_params

    # TODO: WTF is happening here?
    message_complete_callbacks[unsafe_ref(parser).id](r)

    return 0
end
on_message_complete_cb = cfunction(on_message_complete, HTTP_CB...)

immutable ClientParser
    parser::Parser
    settings::ParserSettings

    function ClientParser(on_message_complete::Function)
        parser = Parser()
        http_parser_init(parser)
        message_complete_callbacks[parser.id] = on_message_complete

        settings = ParserSettings(on_message_begin_cb, on_url_cb,
                                  on_status_complete_cb, on_header_field_cb,
                                  on_header_value_cb, on_headers_complete_cb,
                                  on_body_cb, on_message_complete_cb)

        new(parser, settings)
    end
end

function add_data(parser::ClientParser, request_data::String)
    http_parser_execute(parser.parser, parser.settings, request_data)
end

function clean!(parser::ClientParser)
    delete!(partials, parser.parser, nothing)
    delete!(message_complete_callbacks, parser.parser.id, nothing)
end
