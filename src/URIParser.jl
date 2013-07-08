module URIParser
    is_url_char(c) =  ((@assert c < 0x80); 'A' <= c <= '~' || '$' <= c <= '>' || c == 12 || c == 9)
    is_mark(c) = (c == '-') || (c == '_') || (c == '.') || (c == '!') || (c == '~') ||
                 (c == '*') || (c == '\'') || (c == '(') || (c == ')')
    is_userinfo_char(c) = isalnum(c) || is_mark(c) || (c == '%') || (c == ';') || 
                 (c == ':') || (c == '&') || (c == '+') || (c == '$' || c == ',')
    isnum(c) = ('0' <= c <= '9')
    ishex(c) =  (isnum(c) || 'a' <= lowercase(c) <= 'f')
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
            elseif state == :http_host_port || state == :http_host_port_start
                if !isnum(ch)
                    error("Port must be numeric (decimal)")
                end
                state = :http_host_port
            else 
                error("Unexpected state $state")
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

    import Base: show, print
    show(io::IO, uri::URI) = print(io,"URI(",uri,")")

    function print(io::IO, uri::URI) 
        if !isempty(uri.host)
            print(io,uri.schema,"://")
            if !isempty(uri.userinfo)
                print(io,uri.userinfo,'@')
            end
            if contains(uri.host,':') #is IPv6
                print(io,'[',uri.host,']')
            else
                print(io,uri.host)
            end
            if uri.port != 0
                print(io,':',int(uri.port))
            end
        end
        print(io,uri.path)
        if !isempty(uri.query)
            print(io,"?",uri.query)
        end
        if !isempty(uri.fragment)
            print(io,"#",uri.fragment)
        end
    end
end
