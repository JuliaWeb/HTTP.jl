
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

function on_status_complete(parser)
    response_stream = pd(parser)
    response_stream.response.status = (unsafe_load(parser)).status_code
    response_stream.state = StatusComplete
    notify(response_stream.state_change)
    return 0
end

function on_header_field(parser, at, len)
    response_stream = pd(parser)
    header = unsafe_string(convert(Ptr{UInt8}, at))
    header_field = header[1:len]
    if response_stream.state == OnHeaderField
        field = string(get(response_stream.current_header, header_field))
        response_stream.current_header = Nullable(field)
    else
        response_stream.current_header = Nullable(header_field)
    end
    response_stream.state = OnHeaderField
    notify(response_stream.state_change)
    return 0
end

function parse_cookies!(response, cookie_strings)
    for cookie_str in split(cookie_strings, '\0')
        isempty(cookie_str) && continue
        parts = split(cookie_str, ';')
        isempty(parts) && continue
        nameval = split(parts[1], '=', limit=2)
        length(nameval)==2 || continue
        name, value = nameval
        c = Cookie(strip(name), strip(value))
        for part in parts[2:end]
            nameval = split(part, '=', limit=2)
            if length(nameval)==2
                name, value = nameval
                c.attrs[strip(name)] = strip(value)
            else
                c.attrs[strip(nameval[1])] = Compat.String("")
            end
        end
        response.cookies[c.name] = c
    end
    response
end

const is_set_cookie = r"set-cookie"i

function on_header_value(parser, at, len)
    response_stream = pd(parser)
    resp = response_stream.response
    s = unsafe_string(convert(Ptr{UInt8}, at), Int(len))
    current_header = get(response_stream.current_header)
    if response_stream.state == OnHeaderValue
        if is_set_cookie(current_header)
            write(response_stream.cookie_buffer, s)
        else
            resp.headers[current_header] = string(resp.headers[current_header], s)
        end
    else
        if is_set_cookie(current_header)
            write(response_stream.cookie_buffer, '\0', s)
            # maybe_cookie = parse_set_cookie(s)
            # if !isnull(maybe_cookie)
            #     cookie = get(maybe_cookie)
            #     response_stream.response.cookies[cookie.name] = cookie
            # end
        else
            response_stream.response.headers[current_header] = s
        end
    end
    # response_stream.current_header = Nullable()
    response_stream.state = OnHeaderValue
    notify(response_stream.state_change)
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
    parse_cookies!(response, takebuf_string(response_stream.cookie_buffer))

    response_stream.state = HeadersDone
    notify(response_stream.state_change)

    # From https://github.com/nodejs/http-parser/blob/master/http_parser.h
    # Comment starting line 72
    # On a HEAD method return 1 instead of 0 to indicate that the parser
    # should not expect a body.
    method = get( response.request ).method
    if method ∈ ("HEAD", "CONNECT")
        return 1  # Signal HTTP parser to not expect a body
    else
        return 0
    end
end

function on_body(parser, at, len)
    response_stream = pd(parser)
    append!(response_stream.buffer.data, unsafe_wrap(Array, convert(Ptr{UInt8}, at), (len,)))
    response_stream.buffer.size = length(response_stream.buffer.data)
    response_stream.state = OnBody
    notify(response_stream.state_change)
    return 0
end

function on_message_complete(parser)
    response_stream = pd(parser)
    if upgrade(unsafe_load(parser))
        response_stream.state = UpgradeConnection
    else
        response_stream.state = BodyDone
    end
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
    global const on_url_cb = C_NULL # callback valid only for Server, not for Request
    global const on_status_complete_cb = cfunction(on_status_complete, HTTP_CB...)
    global const on_header_field_cb = cfunction(on_header_field, HTTP_DATA_CB...)
    global const on_header_value_cb = cfunction(on_header_value, HTTP_DATA_CB...)
    global const on_headers_complete_cb = cfunction(on_headers_complete, HTTP_CB...)
    global const on_body_cb = cfunction(on_body, HTTP_DATA_CB...)
    global const on_message_complete_cb = cfunction(on_message_complete, HTTP_CB...)
end
