is_url_char(c) =  ((@assert UInt32(c) < 0x80); 'A' <= c <= '~' || '$' <= c <= '>' || c == '\f' || c == '\t')
is_mark(c) = (c == '-') || (c == '_') || (c == '.') || (c == '!') || (c == '~') ||
             (c == '*') || (c == '\'') || (c == '(') || (c == ')')
is_userinfo_char(c) = isalnum(c) || is_mark(c) || (c == '%') || (c == ';') ||
             (c == ':') || (c == '&') || (c == '+') || (c == '$' || c == ',')
isnum(c) = ('0' <= c <= '9')
ishex(c) =  (isnum(c) || 'a' <= lowercase(c) <= 'f')
is_host_char(c) = isalnum(c) || (c == '.') || (c == '-') || (c == '_') || (c == "~")


immutable URI
    scheme::String
    host::String
    port::UInt16
    path::String
    query::String
    fragment::String
    userinfo::String
    specifies_authority::Bool
    URI(scheme,host,port,path,query="",fragment="",userinfo="",specifies_authority=false) =
            new(scheme,host,UInt16(port),path,query,fragment,userinfo,specifies_authority)
end

==(a::URI,b::URI) = (a.scheme   == b.scheme)   &&
                    (a.host     == b.host)     &&
                    (a.port     == b.port)     &&
                    (a.path     == b.path)     &&
                    (a.query    == b.query)    &&
                    (a.fragment == b.fragment) &&
                    (a.userinfo == b.userinfo)

URI(host, path) = URI("http", host, UInt16(80), path, "", "", "", true)

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
    (host, UInt16(port == "" ? 0 : Base.parse(Int,port,10)), user)
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
    path = "/"
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
    return URI(lowercase(scheme),host,port,path,query,fragment,user,specifies_authority)
end

URI(url) = parse_url(url)

Base.show(io::IO, uri::URI) = print(io, "HTTP.URI(\"", uri, "\")")

function Base.print(io::IO, uri::URI)
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
            print(io,':',Int(uri.port))
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

function Base.show(io::IO, ::MIME"text/html", uri::URI)
    print(io, "<a href=\"")
    print(io, uri)
    print(io, "\">")
    print(io, uri)
    print(io, "</a>")
end

const escaped_regex = r"%([0-9a-fA-F]{2})"

# Escaping
const control_array = vcat(map(UInt8, 0:Base.parse(Int,"1f",16)))
const control = String(control_array)*"\x7f"
const space = String(" ")
const delims = String("%<>\"")
const unwise   = String("(){}|\\^`")

const reserved = String(",;/?:@&=+\$![]'*#")
# Strings to be escaped
# (Delims goes first so '%' gets escaped first.)
const unescaped = delims * reserved * control * space * unwise
const unescaped_form = delims * reserved * control * unwise

function unescape(str)
    r = UInt8[]
    l = length(str)
    i = 1
    while i <= l
        c = str[i]
        i += 1
        if c == '%'
            c = Base.parse(UInt8, str[i:i+1], 16)
            i += 2
        end
        push!(r, c)
    end
   return String(r)
end
unescape_form(str) = unescape(replace(str, "+", " "))

hex_string(x) = string('%', uppercase(hex(x,2)))

# Escapes chars (in second string); also escapes all non-ASCII chars.
function escape_with(str, use)
    str = String(str)
    out = IOBuffer()
    chars = Set(use)
    i = start(str)
    e = endof(str)
    while i <= e
        i_next = nextind(str, i)
        if i_next == i + 1
            _char = str[i]
            if _char in chars
                write(out, hex_string(Int(_char)))
            else
                write(out, _char)
            end
        else
            while i < i_next
                write(out, hex_string(str.data[i]))
                i += 1
            end
        end
        i = i_next
    end
    takebuf_string(out)
end

escape(str) = escape_with(str, unescaped)
escape_form(str) = replace(escape_with(str, unescaped_form), " ", "+")

##
# Splits the userinfo portion of an URI in the format user:password and
# returns the components as tuple.
#
# Note: This is just a convenience method, and this form of usage is
# deprecated as of rfc3986.
# See: http://tools.ietf.org/html/rfc3986#section-3.2.1
function userinfo(uri::URI)
    Base.warn_once("Use of the format user:password is deprecated (rfc3986)")
    uinfo = uri.userinfo
    sep = search(uinfo, ':')
    l = length(uinfo)
    username = uinfo[1:(sep-1)]
    password = ((sep == l) || (sep == 0)) ? "" : uinfo[(sep+1):l]
    (username, password)
end

##
# Splits the path into components and parameters
# See: http://tools.ietf.org/html/rfc3986#section-3.3
function splitpath(uri::URI, starting=2)
    elems = String[]
    p = uri.path
    len = length(p)
    len > 1 || return elems
    start_ind = i = starting # p[1] == '/'
    while true
        c = p[i]
        if c == '/' || i == len
            push!(elems, p[start_ind:i-1])
            start_ind = i + 1
        end
        i += 1
        (i > len || c in ('?', '#')) && break
    end
    return elems
end

# Create equivalent URI without the fragment
defrag(uri::URI) = URI(uri.scheme, uri.host, uri.port, uri.path, uri.query, "", uri.userinfo, uri.specifies_authority)

# Validate known URI formats
const uses_authority = ["hdfs", "ftp", "http", "gopher", "nntp", "telnet", "imap", "wais", "file", "mms", "https", "shttp", "snews", "prospero", "rtsp", "rtspu", "rsync", "svn", "svn+ssh", "sftp" ,"nfs", "git", "git+ssh", "ldap"]
const uses_params = ["ftp", "hdl", "prospero", "http", "imap", "https", "shttp", "rtsp", "rtspu", "sip", "sips", "mms", "sftp", "tel"]
const non_hierarchical = ["gopher", "hdl", "mailto", "news", "telnet", "wais", "imap", "snews", "sip", "sips"]
const uses_query = ["http", "wais", "imap", "https", "shttp", "mms", "gopher", "rtsp", "rtspu", "sip", "sips", "ldap"]
const uses_fragment = ["hdfs", "ftp", "hdl", "http", "gopher", "news", "nntp", "wais", "https", "shttp", "snews", "file", "prospero"]

function isvalid(uri::URI)
    scheme = uri.scheme
    isempty(scheme) && error("Can not validate relative URI")
    if ((scheme in non_hierarchical) && (search(uri.path, '/') > 1)) ||       # path hierarchy not allowed
       (!(scheme in uses_query) && !isempty(uri.query)) ||                    # query component not allowed
       (!(scheme in uses_fragment) && !isempty(uri.fragment)) ||              # fragment identifier component not allowed
       (!(scheme in uses_authority) && (!isempty(uri.host) || (0 != uri.port) || !isempty(uri.userinfo))) # authority component not allowed
        return false
    end
    true
end
