
### Response Parsing

immutable ResponseParser
    parser::Parser
    settings::ParserSettings

    function ResponseParser(r)
        parser = Parser()
        parser.data = r
        http_parser_init(parser,false)
        settings = ParserSettings(on_message_begin_cb, on_url_cb,
                          on_status_complete_cb, on_header_field_cb,
                          on_header_value_cb, on_headers_complete_cb,
                          on_body_cb, on_message_complete_cb)

        new(parser, settings)
    end
end

pd(p::Ptr{Parser}) = (unsafe_load(p).data)::ResponseStream

# All the `HttpParser` callbacks to be run in C land
# Each one adds data to the `RequestStream` until it is complete
#
function on_message_begin(parser)
    pd(parser).state = OnMessageBegin
    notify(pd(parser).state_change)
    return 0
end

function on_url(parser, at, len)
    pd(parser).response.resource  =
      string(r.resource, bytestring(convert(Ptr{Uint8}, at), Int(len)))
    return 0
end

function on_status_complete(parser)
    pd(parser).response.status = (unsafe_load(parser)).status_code
    return 0
end

function on_header_field(parser, at, len)
    response_stream = pd(parser)
    header = bytestring(convert(Ptr{Uint8}, at))
    header_field = header[1:len]
    response_stream.current_header = Nullable(header_field)
    return 0
end

function parse_set_cookie(value)
    parts = split(value, ';')
    isempty(parts) && return Nullable{Cookie}()
    nameval = split(parts[1], '=', limit=2)
    length(nameval)==2 || return Nullable{Cookie}()
    name, value = nameval
    c = Cookie(strip(name), strip(value))
    for part in parts[2:end]
        nameval = split(part, '=', limit=2)
        if length(nameval)==2
            name, value = nameval
            c.attrs[strip(name)] = strip(value)
        else
            c.attrs[strip(nameval[1])] = utf8("")
        end
    end
    return Nullable(c)
end

const is_set_cookie = r"set-cookie"i

function on_header_value(parser, at, len)
    response_stream = pd(parser)
    s = bytestring(convert(Ptr{Uint8}, at), Int(len))
    current_header = get(response_stream.current_header)
    if is_set_cookie(current_header)
        maybe_cookie = parse_set_cookie(s)
        if !isnull(maybe_cookie)
            cookie = get(maybe_cookie)
            response_stream.response.cookies[cookie.name] = cookie
        end
    else
        response_stream.response.headers[current_header] = s
    end
    response_stream.current_header = Nullable()
    return 0
end

function on_headers_complete(parser)
    response_stream = pd(parser)
    response = response_stream.response
    p = unsafe_load(parser)
    # get first two bits of p.type_and_flags
    ptype = p.type_and_flags & 0x03
    if ptype == 0
        response.method = http_method_str(convert(Int, p.method))
    elseif ptype == 1
        response.headers["status_code"] = string(convert(Int, p.status_code))
    end
    response.headers["http_major"] = string(convert(Int, p.http_major))
    response.headers["http_minor"] = string(convert(Int, p.http_minor))
    response.headers["Keep-Alive"] = string(http_should_keep_alive(parser))
    response_stream.state = HeadersDone
    notify(response_stream.state_change)
    return 0
end

function on_body(parser, at, len)
    response_stream = pd(parser)
    append!(response_stream.buffer.data, pointer_to_array(convert(Ptr{UInt8}, at), (len,)))
    response_stream.buffer.size = length(response_stream.buffer.data)
    response_stream.state = OnBody
    notify(response_stream.state_change)
    return 0
end

function on_message_complete(parser)
    response_stream = pd(parser)
    response_stream.state = BodyDone
    notify(response_stream.state_change)
    return 0
end

# Passes `request_data` into `parser`
function add_data(parser::ResponseParser, request_data)
    http_parser_execute(parser.parser, parser.settings, request_data)
end

# Datatype Tuples for the different `cfunction` signatures used by `HttpParser`
const HTTP_CB      = (Int, (Ptr{Parser},))
const HTTP_DATA_CB = (Int, (Ptr{Parser}, Ptr{Cchar}, Csize_t,))


function __init_parsing__()
    # Turn all the callbacks into C callable functions.
    global const on_message_begin_cb = cfunction(on_message_begin, HTTP_CB...)
    global const on_url_cb = cfunction(on_url, HTTP_DATA_CB...)
    global const on_status_complete_cb = cfunction(on_status_complete, HTTP_CB...)
    global const on_header_field_cb = cfunction(on_header_field, HTTP_DATA_CB...)
    global const on_header_value_cb = cfunction(on_header_value, HTTP_DATA_CB...)
    global const on_headers_complete_cb = cfunction(on_headers_complete, HTTP_CB...)
    global const on_body_cb = cfunction(on_body, HTTP_DATA_CB...)
    global const on_message_complete_cb = cfunction(on_message_complete, HTTP_CB...)
end
