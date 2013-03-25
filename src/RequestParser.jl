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
export RequestParser,
       clean!,
       add_data

# Datatype Tuples for the different `cfunction` signatures used by `HttpParser`
HTTP_CB      = (Int, (Ptr{Parser},))
HTTP_DATA_CB = (Int, (Ptr{Parser}, Ptr{Cchar}, Csize_t,))

# Need an empty constructor method for building `Request` instances.
import Httplib.Request
Request() = Request("", "", Httplib.headers(), "", Dict{Any, Any}())

import Httplib.Request
Request(r::PartialRequest) = Request(r.method, r.resource, r.headers, r.data, Dict())

# IMPORTANT!!! This requires manual memory management.
#
# Each Client needs its own `Request`. Since closures are not
# c-callable, we have to keep a global dictionary of Parser pointers
# to the in-progress `Request`. Callbacks will lookup their partial in this
# global dict. Partials must be manually deleted when connections
# are closed or memory leaks will occur.
#
partials = Dict{Ptr{Parser}, Request}()
message_complete_callbacks = Dict{Int, Function}()

# All the `HttpParser` callbacks to be run in C land
# Each one adds data to the `Request` until it is complete
#
function on_message_begin(parser)
    partials[parser] = Request()
    return 0
end

function on_url(parser, at, len)
    r = partials[parser]
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
    r = partials[parser]
    header = bytestring(convert(Ptr{Uint8}, at))
    header_field = header[1:len]
    r.headers["current_header"] = header_field
    return 0
end

function on_header_value(parser, at, len)
    r = partials[parser]
    s = bytestring(convert(Ptr{Uint8}, at),int(len))
    r.headers[r.headers["current_header"]] = s
    r.headers["current_header"] = ""
    return 0
end

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

function on_body(parser, at, len)
    r = partials[parser]
    r.data = string(r.data, bytestring(convert(Ptr{Uint8}, at)))
    return 0
end

function on_message_complete(parser)
    r = partials[parser]

    # delete the temporary header key
    delete!(r.headers, "current_header", nothing)

    # Decode URL variables eg. `foo/bar?a=b&c=d`
    # Store in `r.state[:url_params]`
    #
    m = match(r"\?.*=.*", r.resource)
    url_params = (String => String)[]
    if m != nothing
        for set in split(split(r.resource, "?")[2], "&")
            key, val = split(set, "=")
            url_params[key] = val
        end
    end

    # Add finishing touches to `Request`
    raw_resource = r.resource
    r.resource = split(r.resource,'?')[1]
    r.state[:raw_resource] = raw_resource
    r.state[:url_params]   = url_params

    # Get the `parser.id` from the C pointer `parser`.
    # Retrieve our callback function from the global Dict.
    # Call it with the completed `Request`
    #
    message_complete_callbacks[unsafe_ref(parser).id](r)

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

# `ClientParser` wraps our `HttpParser`
# Constructed with `on_message_complete` function.
#
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

# Passes `request_data` into `parser`
function add_data(parser::ClientParser, request_data::String)
    http_parser_execute(parser.parser, parser.settings, request_data)
end

# Garbage collect all data associated with `parser` from the global Dicts.
# Call this whenever closing a connection that has a `ClientParser` instance.
#
function clean!(parser::ClientParser)
    delete!(partials, parser.parser, nothing)
    delete!(message_complete_callbacks, parser.parser.id, nothing)
end
