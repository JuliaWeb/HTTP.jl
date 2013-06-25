module HttpClient
    using HttpParser
    using HttpCommon

    export URI, get, post

    ## URI Parsing

    CRLF = "\r\n"

    module URIParser

        normal_url_char = bitpack([
        #   0 nul    1 soh    2 stx    3 etx    4 eot    5 enq    6 ack    7 bel  */
                0    ,   0    ,   0    ,   0    ,   0    ,   0    ,   0    ,   0,
        #   8 bs     9 ht     10 nl    11 vt    12 np    13 cr    14 so    15 si   */
                0    ,   1    ,   0    ,   0    ,   1    ,   0    ,   0    ,   0,
        #   16 dle   17 dc1   18 dc2   19 dc3   20 dc4   21 nak   22 syn   23 etb */
                0    ,   0    ,   0    ,   0    ,   0    ,   0    ,   0    ,   0,
        #   24 can   25 em    26 sub   27 esc   28 fs    29 gs    30 rs    31 us  */
                0    ,   0    ,   0    ,   0    ,   0    ,   0    ,   0    ,   0,
        #   32 sp    33  !    34  "    35  #    36  $    37  %    38  &    39  \'  */
                0    ,   1    ,   1    ,   0    ,   1    ,   1    ,   1    ,   1,
        #   40  (    41  )    42  *    43  +    44  ,    45  -    46  .    47  /  */
                1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1,
        #   48  0    49  1    50  2    51  3    52  4    53  5    54  6    55  7  */
                1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1,
        #   56  8    57  9    58  :    59  ;    60  <    61  =    62  >    63  ?  */
                1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   0,
        #   64  @    65  A    66  B    67  C    68  D    69  E    70  F    71  G  */
                1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1,
        #   72  H    73  I    74  J    75  K    76  L    77  M    78  N    79  O  */
                1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1,
        #   80  P    81  Q    82  R    83  S    84  T    85  U    86  V    87  W  */
                1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1,
        #   88  X    89  Y    90  Z    91  [    92  \    93  ]    94  ^    95  _  */
                1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1,
        #   96  `    97  a    98  b    99  c   100  d   101  e   102  f   103  g  */
                1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1,
        #  104  h   105  i   106  j   107  k   108  l   109  m   110  n   111  o  */
                1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1,
        #  112  p   113  q   114  r   115  s   116  t   117  u   118  v   119  w  */
                1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1,
        #  120  x   121  y   122  z   123  {   124  |   125  }   126  ~   127 del */
                1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   1    ,   0])

        is_url_char(c) = ((@assert c < 0x80);normal_url_char[uint8(c)])
        is_mark(c) = (c == '-') || (c == '_') || (c == '.') || (c == '!') || (c == '~') ||
                     (c == '*') || (c == '\'') || (c == '(') || (c == ')')
        is_userinfo_char(c) = isalnum(c) || is_mark(c) || (c == '%') || (c == ';') || 
                     (c == ':') || (c == '&') || (c == '+') || (c == '$' || c == ',')
        ishex(c) =  ('0' <= c <= '9' || 'a' <= lowercase(c) <= 'f')
        is_host_char(c) = isalnum(c) || (c == '.') || (c == '-')


        export URI
        immutable URI
            schema::ASCIIString
            host::ASCIIString
            port::Uint16
            path::ASCIIString
            query::ASCIIString
            fragment::ASCIIString
            userinfo::ASCIIString

        end

        URI(schema::ASCIIString,host::ASCIIString,port::Integer,path,query::ASCIIString="",fragment="",userinfo="") = 
            new(schema,host,uint16(port),path,query,fragment,user)
        URI(host,path) = URI("http",host,uint16(80),path,"","",no_user)

        
        # URL parser based on the http-parser package by Joyent
        # Licensed under the BSD license

        # Parse authority (user@host:port)
        # return (host,port,user)
        function parse_authority(authority,seen_at)
            host=""
            port=""
            user=""
            last_state = state = seen_at ? :http_userinfo_start : :http_host_start
            i = start(authority)
            li = s = 0
            while true
                if done(authority,li)
                    last_state = state
                    state = :done
                end

                if s == 0 
                    s = li
                end

                if state != last_state
                    r = s:prevind(authority,li)
                    s = li
                    if last_state == :http_userinfo
                        user = authority[r]
                    elseif last_state == :http_host || last_state == :http_host_v6
                        host = authority[r]
                    elseif last_state == :http_host_port
                        port = authority[r]
                    end
                end

                if state == :done
                    break
                end

                if done(authority,i)
                    li = i
                    continue
                end

                li = i
                (ch,i) = next(authority,i)

                last_state = state
                if state == :http_userinfo || state == :http_userinfo_start
                    if ch == '@'
                        state = :http_host_start
                    elseif is_userinfo_char(ch)
                        state = :http_userinfo
                    else
                        error("Unexpected character '$ch' in userinfo")
                    end
                elseif state == :http_host_start
                    if ch == '['
                        state = :http_host_v6_start
                    elseif is_host_char(ch)
                        state = :http_host
                    else
                        error("Unexpected character '$ch' at the beginning of the host string")
                    end
                elseif state == :http_host
                    if ch == ':'
                        state = :http_host_port_start
                    elseif !is_host_char(ch)
                        error("Unexpected character '$ch' in host")
                    end
                elseif state == :http_host_v6_end
                    if ch != ':'
                        error("Only port allowed in authority after IPv6 address")
                    end
                    state = :http_host_port_start
                elseif state == :http_host_v6 || state == :http_host_v6_start
                    if ch == ']' && state == :http_host_v6
                        state = :http_host_v6_end
                    elseif ishex(ch) || ch == ':' || ch == '.'
                        state = :http_host_v6
                    else
                        error("Unrecognized character in IPv6 address")
                    end
                elseif state == :http_host_port || :http_host_port_start
                    if !isnum(ch)
                        error("Port must be numeric (decimal)")
                    end
                end
            end
            (host,uint16(port==""?0:parseint(port,10)),user)
        end

        function parse_url(url)
            schema = ""
            host = ""
            server = ""
            port = 80
            query = ""
            fragment = ""
            username = ""
            pass = ""
            path = ""
            last_state = state = :req_spaces_before_url
            seen_at = false

            i = start(url)
            li = s = 0
            while true
                if done(url,li)
                    last_state = state
                    state = :done
                end

                if s == 0 
                    s = li
                end

                if state != last_state
                    r = s:prevind(url,li)
                    s = li
                    if last_state == :req_schema
                        schema = url[r]
                    elseif last_state == :req_server
                        server = url[r]
                    elseif last_state == :req_query_string
                        query = url[r]
                    elseif last_state == :req_path
                        path = url[r]
                    elseif last_state == :req_fragment
                        fragment = url[r]
                    end
                end

                if state == :done
                    break
                end

                if done(url,i)
                    li = i
                    continue
                end

                li = i
                (ch,i) = next(url,i)

                if !isascii(ch)
                    "Non-ASCII characters not supported in URIs. Encode the URL and try again."
                end

                last_state = state

                if state == :req_spaces_before_url
                    if ch == '/' || ch == '*'
                        state = :req_path
                    elseif isalpha(ch)
                        state = :req_schema
                    else
                        error("Unexpected start of URL")
                    end
                elseif state == :req_schema 
                    if ch == ':'
                        state = :req_schema_slash
                    elseif !isalpha(ch)
                        error("Unexpected character $ch after schema")
                    end
                elseif state == :req_schema_slash
                    if ch == '/'
                        state = :req_schema_slash_slash
                    elseif is_url_char(ch)
                        state = :req_path
                    else 
                        error("Expecting schema:path schema:/path  format not schema:$ch")
                    end
                elseif state == :req_schema_slash_slash
                    if ch == '/'
                        state = :req_server_start
                    elseif is_url_char(ch)
                        s -= 1
                        state = :req_path
                    else 
                        error("Expecting schema:// or schema: format not schema:/$ch")
                    end
                elseif state == :req_server_start || state == :req_server
                    if ch == '/' && state == :req_server
                        state = :req_path
                    elseif ch == '?'
                        state = :req_query_string_start
                    elseif ch == '@'
                        seen_at = true
                        state = :req_server
                    elseif is_userinfo_char(ch) || ch == '[' || ch == ']'
                        state = :req_server
                    else
                        error("Unexpected character $ch in server")
                    end
                elseif state == :req_path
                    if ch == '?'
                        state = :req_query_string_start
                    elseif ch == '#'
                        state = :req_fragment_start
                    elseif !is_url_char(ch)
                        error("Path contained unxecpected character")
                    end
                elseif state == :req_query_string_start || state == :req_query_string
                    if ch == '?'
                        state = :s_req_query_string
                    elseif ch == '#'
                        state = :s_req_fragment_start
                    elseif !is_url_char(ch)
                        error("Query String contained unxecpected character")
                    end
                elseif state == :s_req_fragment_start
                    if ch == '?'
                        state = :req_fragment
                    elseif ch == '#'
                        state = :s_req_fragment_start
                    elseif ch != '#' && !is_url_char(ch)
                        error("Start of Fragement contained unxecpected character")
                    end
                elseif state == :req_fragment
                    if !is_url_char && ch != '?' && ch != '#'
                        error("Fragement contained unxecpected character")
                    end
                end
            end
            host, port, user = parse_authority(server,seen_at)
            URI(lowercase(schema),host,port,path,query,fragment,user)
        end

        URI(url) = parse_url(url)
    end

    import .URIParser.URI

    function render(request::Request)
        join([
            request.method*" "*request.resource*" HTTP/1.1",
            map(h->(h*": "*request.headers[h]),collect(keys(request.headers))),
            "",
            request.data],CRLF)
    end

    function default_get_request(resource,host)
        Request("GET",resource,(String => String)[
            "User-Agent" => "HttpClient.jl/0.0.0",
            "Host" => host,
            "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
            ],"")
    end

    ### Response Parsing


    type ResponseParserData
        current_response::Response
        sock::AsyncStream
    end

    immutable ResponseParser
        parser::Parser 
        settings::ParserSettings

        function ResponseParser(r,sock)
            parser = Parser()
            parser.data = ResponseParserData(r,sock)
            http_parser_init(parser,false)
            settings = ParserSettings(on_message_begin_cb, on_url_cb,
                              on_status_complete_cb, on_header_field_cb,
                              on_header_value_cb, on_headers_complete_cb,
                              on_body_cb, on_message_complete_cb)

            new(parser, settings)
        end
    end

    pd(p::Ptr{Parser}) = (unsafe_load(p).data)::ResponseParserData


    # Datatype Tuples for the different `cfunction` signatures used by `HttpParser`
    HTTP_CB      = (Int, (Ptr{Parser},))
    HTTP_DATA_CB = (Int, (Ptr{Parser}, Ptr{Cchar}, Csize_t,))


    # All the `HttpParser` callbacks to be run in C land
    # Each one adds data to the `Request` until it is complete
    #
    function on_message_begin(parser)
        #unsafe_ref(parser).data = Response()
        return 0
    end

    function on_url(parser, at, len)
        r = pd(parser).current_response
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
        r = pd(parser).current_response
        header = bytestring(convert(Ptr{Uint8}, at))
        header_field = header[1:len]
        r.headers["current_header"] = header_field
        return 0
    end

    function on_header_value(parser, at, len)
        r = pd(parser).current_response
        s = bytestring(convert(Ptr{Uint8}, at),int(len))
        r.headers[r.headers["current_header"]] = s
        r.headers["current_header"] = ""
        return 0
    end

    function on_headers_complete(parser)
        r = pd(parser).current_response
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
        r = pd(parser).current_response
        r.data = string(r.data, bytestring(convert(Ptr{Uint8}, at)))
        return 0
    end

    function on_message_complete(parser)
        p = pd(parser)
        r = p.current_response
        close(p.sock)

        # delete the temporary header key
        delete!(r.headers, "current_header", nothing)
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

    # Garbage collect all data associated with `parser` from the global Dicts.
    # Call this whenever closing a connection that has a `ClientParser` instance.
    #
    function clean!(parser::ClientParser)
        delete!(message_complete_callbacks, parser.parser.id, nothing)
    end

    # Passes `request_data` into `parser`
    function add_data(parser::ResponseParser, request_data::String)
        http_parser_execute(parser.parser, parser.settings, request_data)
    end

    ### API

    function get(uri::URI)
        if uri.schema != "http"
            error("Unsupported schema \"$(uri.schema)\"")
        end
        ip = Base.getaddrinfo(uri.host)
        sock = connect(ip, uri.port == 0 ? 80 : uri.port)
        resource = uri.path
        if uri.query != ""
            resource = resource*"?"*uri.query
        end
        write(sock, render(default_get_request(resource,uri.host)))
        r = Response()
        rp = ResponseParser(r,sock)
        while sock.open
            data = readavailable(sock)
            print(data)
            add_data(rp, data)
        end
        r
    end 

    get(string::ASCIIString) = get(URI(string))
end