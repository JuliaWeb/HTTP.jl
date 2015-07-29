is_url_char(c) =  ((@assert c < 0x80); 'A' <= c <= '~' || '$' <= c <= '>' || c == 12 || c == 9)
is_mark(c) = (c == '-') || (c == '_') || (c == '.') || (c == '!') || (c == '~') ||
             (c == '*') || (c == '\'') || (c == '(') || (c == ')')
is_userinfo_char(c) = isalnum(c) || is_mark(c) || (c == '%') || (c == ';') ||
             (c == ':') || (c == '&') || (c == '+') || (c == '$' || c == ',')
isnum(c) = ('0' <= c <= '9')
ishex(c) =  (isnum(c) || 'a' <= lowercase(c) <= 'f')
is_host_char(c) = isalnum(c) || (c == '.') || (c == '-') || (c == '_') || (c == "~")


immutable URI
    scheme::ASCIIString
    host::ASCIIString
    port::UInt16
    path::ASCIIString
    query::ASCIIString
    fragment::ASCIIString
    userinfo::ASCIIString
    specifies_authority::Bool
    URI(scheme,host,port,path,query="",fragment="",userinfo="",specifies_authority=false) =
            new(scheme,host,@compat(UInt16(port)),path,query,fragment,userinfo,specifies_authority)
end

==(a::URI,b::URI) = isequal(a,b)
isequal(a::URI,b::URI) = (a.scheme == b.scheme) &&
                         (a.host == b.host) &&
                         (a.port == b.port) &&
                         (a.path == b.path) &&
                         (a.query == b.query) &&
                         (a.fragment == b.fragment) &&
                         (a.userinfo == b.userinfo)

URI(host,path) = URI("http",host,@compat(UInt16(80)),path,"","","",true)
URI(uri::URI; scheme=nothing, host=nothing, port=nothing, path=nothing, query=nothing, fragment=nothing, userinfo=nothing, specifies_authority=nothing) =
URI(scheme === nothing ? uri.scheme : scheme,
    host === nothing ? uri.host : host,
    port === nothing ? uri.port : port,
    path === nothing ? uri.path : path,
    query === nothing ? uri.query : query,
    fragment === nothing ? uri.fragment : fragment,
    userinfo === nothing ? uri.userinfo : userinfo,
    specifies_authority === nothing ? uri.specifies_authority : specifies_authority)

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
    (host, @compat(UInt16(port == "" ? 0 : parse(Int,port,10))), user)
end

function parse_url(url)
    scheme = ""
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
    specifies_authority = false

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
            if last_state == :req_scheme
                scheme = url[r]
            elseif last_state == :req_server_start
                specifies_authority = true
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
            error("Non-ASCII characters not supported in URIs. Encode the URL and try again.")
        end

        last_state = state

        if state == :req_spaces_before_url
            if ch == '/' || ch == '*'
                state = :req_path
            elseif isalpha(ch)
                state = :req_scheme
            else
                error("Unexpected start of URL")
            end
        elseif state == :req_scheme
            if ch == ':'
                state = :req_scheme_slash
            elseif !(isalpha(ch) || isdigit(ch) || ch == '+' || ch == '-' || ch == '.')
                error("Unexpected character $ch after scheme")
            end
        elseif state == :req_scheme_slash
            if ch == '/'
                state = :req_scheme_slash_slash
            elseif is_url_char(ch)
                state = :req_path
            else
                error("Expecting scheme:path scheme:/path  format not scheme:$ch")
            end
        elseif state == :req_scheme_slash_slash
            if ch == '/'
                state = :req_server_start
            elseif is_url_char(ch)
                s -= 1
                state = :req_path
            else
                error("Expecting scheme:// or scheme: format not scheme:/$ch")
            end
        elseif state == :req_server_start || state == :req_server
            # In accordence with RFC3986:
            # 'The authority component is preceded by a double slash ("//") and isterminated by the next slash ("/")'
            # This is different from the joyent http-parser, which considers empty hosts to be invalid. c.f. also the
            # following part of RFC 3986:
            # "If the URI scheme defines a default for host, then that default
            # applies when the host subcomponent is undefined or when the
            # registered name is empty (zero length).  For example, the "file" URI
            # scheme is defined so that no authority, an empty host, and
            # "localhost" all mean the end-user's machine, whereas the "http"
            # scheme considers a missing authority or empty host invalid."
            if ch == '/'
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
            elseif !is_url_char(ch) && ch != '@'
                error("Path contained unexpected character")
            end
        elseif state == :req_query_string_start || state == :req_query_string
            if ch == '?'
                state = :req_query_string
            elseif ch == '#'
                state = :req_fragment_start
            elseif !is_url_char(ch)
                error("Query string contained unexpected character")
            else
                state = :req_query_string
            end
        elseif state == :req_fragment_start
            if ch == '?'
                state = :req_fragment
            elseif ch == '#'
                state = :req_fragment_start
            elseif ch != '#' && !is_url_char(ch)
                error("Start of fragment contained unexpected character")
            else
                state = :req_fragment
            end
        elseif state == :req_fragment
            if !is_url_char(ch) && ch != '?' && ch != '#'
                error("Fragment contained unexpected character")
            end
        else
            error("Unrecognized state")
        end
    end
    host, port, user = parse_authority(server,seen_at)
    URI(lowercase(scheme),host,port,path,query,fragment,user,specifies_authority)
end

URI(url) = parse_url(url)

show(io::IO, uri::URI) = print(io,"URI(",uri,")")

function print(io::IO, uri::URI)
    if uri.specifies_authority || !isempty(uri.host)
        print(io,uri.scheme,"://")
        if !isempty(uri.userinfo)
            print(io,uri.userinfo,'@')
        end
        if ':' in uri.host #is IPv6
            print(io,'[',uri.host,']')
        else
            print(io,uri.host)
        end
        if uri.port != 0
            print(io,':',@compat(Int(uri.port)))
        end
    else
        print(io,uri.scheme,":")
    end
    print(io,uri.path)
    if !isempty(uri.query)
        print(io,"?",uri.query)
    end
    if !isempty(uri.fragment)
        print(io,"#",uri.fragment)
    end
end

