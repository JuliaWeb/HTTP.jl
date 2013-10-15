module WWWClient
    using HttpParser
    using HttpCommon
    using URIParser
    using GnuTLS
    using Codecs

    export URI, get, post, put, delete

    ## URI Parsing

    CRLF = "\r\n"

    import URIParser.URI

    function render(request::Request)
        join([
            request.method*" "*(isempty(request.resource)?"/":request.resource)*" HTTP/1.1",
            map(h->(h*": "*request.headers[h]),collect(keys(request.headers))),
            "",
            request.data],CRLF)
    end

    function default_request(method,resource,host,data,user_headers=Dict{None,None}())
        headers = (String => String)[
            "User-Agent" => "WWWClient.jl/0.0.0",
            "Host" => host,
            "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
            ]
        if !isempty(data)
            headers["Content-Length"] = dec(length(data))
        end
        merge!(headers,user_headers)
        Request(method,resource,headers,data)
    end

    ### Response Parsing


    type ResponseParserData
        current_response::Response
        sock::IO
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
        pd(parser).current_response.status = (unsafe_load(parser)).status_code
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

    function open_stream(uri::URI,headers,data,method)
        if uri.schema != "http" && uri.schema != "https"
            error("Unsupported schema \"$(uri.schema)\"")
        end
        ip = Base.getaddrinfo(uri.host)
        if uri.schema == "http"
            stream = connect(ip, uri.port == 0 ? 80 : uri.port)
        else
            # Initialize HTTPS
            sock = connect(ip, uri.port == 0 ? 443 : uri.port)
            stream = GnuTLS.Session()
            set_priority_string!(stream)
            set_credentials!(stream,GnuTLS.CertificateStore())
            associate_stream(stream,sock)
            handshake!(stream)
        end
        if uri.userinfo != "" && !haskey(headers,"Authorization")
            headers["Authorization"] = "Basic "*bytestring(encode(Base64, uri.userinfo))
        end
        resource = uri.path
        if uri.query != ""
            resource = resource*"?"*uri.query
        end
        write(stream, render(default_request(method,resource,uri.host,data,headers)))
        stream
    end

    function process_response(stream)
        r = Response()
        rp = ResponseParser(r,stream)
        while isopen(stream)
            data = readavailable(stream)
            add_data(rp, data)
        end
        http_parser_execute(rp.parser,rp.settings,"") #EOF
        r
    end

    # 
    get(uri::URI; headers = Dict{String,String}()) = process_response(open_stream(uri,headers,"","GET"))
    delete(uri::URI; headers = Dict{String,String}()) = process_response(open_stream(uri,headers,"","DELETE"))
    function post(uri::URI, data::String; headers = Dict{String,String}())
        process_response(open_stream(uri,headers,data,"POST"))
    end
    function put(uri::URI, data::String; headers = Dict{String,String}())
        process_response(open_stream(uri,headers,data,"PUT"))
    end

    get(string::ASCIIString) = get(URI(string))
    delete(string::ASCIIString) = delete(URI(string))
end
