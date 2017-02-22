# URI
immutable Offset
    off::UInt16
    len::UInt16
end
Offset() = Offset(0, 0)
Base.getindex(A::Vector{UInt8}, o::Offset) = A[o.off:(o.off + o.len - 1)]
Base.isempty(o::Offset) = o.off == 0x0000 && o.len == 0x0000
==(a::Offset, b::Offset) = a.off == b.off && a.len == b.len
const EMPTYOFFSET = Offset()

"""
    HTTP.URI(host; userinfo="", path="", query="", fragment="", isconnect=false)
    HTTP.URI(; scheme="", hostname="", port="", ...)
    parse(HTTP.URI, str::String; isconnect=false)

A type representing a valid uri. Can be constructed from distinct parts using the various
supported keyword arguments. With a raw, already-encoded uri string, use `parse(HTTP.URI, str)`
to parse the `HTTP.URI` directly. The `HTTP.URI` constructors will automatically escape any provided
`query` arguments, typically provided as `"key"=>"value"::Pair` or `Dict("key"=>"value")`.
Note that multiple values for a single query key can provided like `Dict("key"=>["value1", "value2"])`.

For efficiency, the internal representation is stored as a set of offsets and lengths to the various uri components.
To access and return these components as strings, use the various accessor methods:
  * `HTTP.scheme`: returns the scheme (if any) associated with the uri
  * `HTTP.userinfo`: returns the userinfo (if any) associated with the uri
  * `HTTP.hostname`: returns the hostname only of the uri
  * `HTTP.port`: returns the port of the uri; will return "80" or "443" by default if the scheme is "http" or "https", respectively
  * `HTTP.host`: returns the "hostname:port" combination
  * `HTTP.path`: returns the path for a uri
  * `HTTP.query`: returns the query for a uri
  * `HTTP.fragment`: returns the fragment for a uri
  * `HTTP.resource`: returns the path-query-fragment combination
"""
immutable URI
    data::Vector{UInt8}
    offsets::NTuple{7, Offset}
end

const URL = URI

function URI(;hostname::String="", path::String="",
            scheme::String="", userinfo::String="",
            port::Union{Integer,String}="", query="",
            fragment::String="", isconnect::Bool=false)
    hostname != "" && scheme == "" && !isconnect && (scheme = "http")
    io = IOBuffer()
    printuri(io, scheme, userinfo, hostname, string(port), path, escape(query), fragment)
    return Base.parse(URI, String(take!(io)); isconnect=isconnect)
end

# we assume `str` is at least hostname & port
# if all others keywords are empty, assume CONNECT
# can include path, userinfo, query, & fragment
function URI(str::String; userinfo::String="", path::String="",
                          query="", fragment::String="",
                          isconnect::Bool=false)
    if str != ""
        if startswith(str, "http") || startswith(str, "https")
            str = string(str, path, ifelse(query == "", "", "?" * escape(query)),
                         ifelse(fragment == "", "", "#$fragment"))
        else
            if startswith(str, "/") || str == "*"
                # relative uri like "/" or "*", leave it alone
            elseif path == "" && userinfo == "" && query == "" && fragment == "" && ':' in str
                isconnect = true
            else
                str = string("http://", userinfo == "" ? "" : "$userinfo@",
                             str, path, ifelse(query == "", "", "?" * escape(query)),
                             ifelse(fragment == "", "", "#$fragment"))
            end
        end
    end
    return Base.parse(URI, str; isconnect=isconnect)
end
Base.parse(::Type{URI}, str::String; isconnect::Bool=false) = http_parser_parse_url(Vector{UInt8}(str), 1, sizeof(str), isconnect)

==(a::URI,b::URI) = scheme(a)   == scheme(b)    &&
                    hostname(a) == hostname(b)  &&
                    path(a)     == path(b)      &&
                    query(a)    == query(b)     &&
                    fragment(a) == fragment(b)  &&
                    userinfo(a) == userinfo(b)  &&
                    ((!hasport(a) || !hasport(b)) || (port(a) == port(b)))

# accessors
for uf in instances(HTTP.http_parser_url_fields)
    uf == UF_MAX && break
    nm = lowercase(string(uf)[4:end])
    has = Symbol(string("has", nm))
    @eval $has(uri::URI) = uri.offsets[Int($uf)].len > 0
    uf == UF_PORT && continue
    @eval $(Symbol(nm))(uri::URI) = String(uri.data[uri.offsets[Int($uf)]])
end

# special def for port
function port(uri::URI)
    if hasport(uri)
        return String(uri.data[uri.offsets[Int(UF_PORT)]])
    else
        sch = scheme(uri)
        return sch == "http" ? "80" : sch == "https" ? "443" : ""
    end
end

resource(uri::URI; isconnect::Bool=false) = isconnect ? host(uri) : path(uri) * (isempty(query(uri)) ? "" : "?$(query(uri))") * (isempty(fragment(uri)) ? "" : "#$(fragment(uri))")
host(uri::URI) = hostname(uri) * (isempty(port(uri)) ? "" : ":$(port(uri))")

Base.show(io::IO, uri::URI) = print(io, "HTTP.URI(\"", uri, "\")")

Base.print(io::IO, u::URI) = printuri(io, scheme(u), userinfo(u), hostname(u), port(u), path(u), query(u), fragment(u))
function printuri(io::IO, sch::String, userinfo::String, hostname::String, port::String, path::String, query::String, fragment::String)
    if sch in uses_authority
        print(io, sch, "://")
        !isempty(userinfo) && print(io, userinfo, "@")
        print(io, ':' in hostname ? "[$hostname]" : hostname)
        print(io, ((sch == "http" && port == "80") ||
                   (sch == "https" && port == "443") || isempty(port)) ? "" : ":$port")
    elseif path != "" && path != "*" && sch != ""
        print(io, sch, ":")
    elseif hostname != "" && port != "" # CONNECT
        print(io, hostname, ":", port)
    end
    print(io, path, isempty(query) ? "" : "?$query", isempty(fragment) ? "" : "#$fragment")
end

# Validate known URI formats
const uses_authority = ["hdfs", "ftp", "http", "gopher", "nntp", "telnet", "imap", "wais", "file", "mms", "https", "shttp", "snews", "prospero", "rtsp", "rtspu", "rsync", "svn", "svn+ssh", "sftp" ,"nfs", "git", "git+ssh", "ldap", "s3"]
const uses_params = ["ftp", "hdl", "prospero", "http", "imap", "https", "shttp", "rtsp", "rtspu", "sip", "sips", "mms", "sftp", "tel"]
const non_hierarchical = ["gopher", "hdl", "mailto", "news", "telnet", "wais", "imap", "snews", "sip", "sips"]
const uses_query = ["http", "wais", "imap", "https", "shttp", "mms", "gopher", "rtsp", "rtspu", "sip", "sips", "ldap"]
const uses_fragment = ["hdfs", "ftp", "hdl", "http", "gopher", "news", "nntp", "wais", "https", "shttp", "snews", "file", "prospero"]

"checks if a `HTTP.URI` is valid"
function Base.isvalid(uri::URI)
    sch = scheme(uri)
    isempty(sch) && throw(ArgumentError("can not validate relative URI"))
    if ((sch in non_hierarchical) && (search(path(uri), '/') > 1)) ||       # path hierarchy not allowed
       (!(sch in uses_query) && !isempty(query(uri))) ||                    # query component not allowed
       (!(sch in uses_fragment) && !isempty(fragment(uri))) ||              # fragment identifier component not allowed
       (!(sch in uses_authority) && (!isempty(hostname(uri)) || ("" != port(uri)) || !isempty(userinfo(uri)))) # authority component not allowed
        return false
    end
    return true
end

lower(c::UInt8) = c | 0x20
@inline shouldencode(c) = c < 0x1f || c > 0x7f || @anyeq(c,
                            UInt8(';'), UInt8('/'), UInt8('?'), UInt8(':'),
                            UInt8('@'), UInt8('='), UInt8('&'), UInt8(' '),
                            UInt8('"'), UInt8('<'), UInt8('>'), UInt8('#'),
                            UInt8('%'), UInt8('{'), UInt8('}'), UInt8('|'),
                            UInt8('\\'), UInt8('^'), UInt8('~'), UInt8('['),
                            UInt8(']'), UInt8('`'))
hexstring(x) = string('%', uppercase(hex(x,2)))

"percent-encode a string, dict, or pair for a uri"
function escape end

escape(v::Number) = string(v)
escape{T}(v::Nullable{T}) = Base.isnull(v) ? "" : string(get(v))
function escape(str::AbstractString, f=shouldencode)
    out = IOBuffer()
    for c in Vector{UInt8}(str)
        write(out, f(c) ? hexstring(Int(c)) : c)
    end
    return String(take!(out))
end

escape(io, k, v) = write(io, escape(k), "=", escape(v))
function escape(io, k, A::Vector{String})
    len = length(A)
    for (i, v) in enumerate(A)
        write(io, escape(k), "=", escape(v))
        i == len || write(io, "&")
    end
end

escape(p::Pair) = escape(Dict(p))
function escape(d::Dict)
    io = IOBuffer()
    len = length(d)
    for (i, (k,v)) in enumerate(d)
        escape(io, k, v)
        i == len || write(io, "&")
    end
    return String(take!(io))
end

"unescape a percent-encoded uri/url"
function unescape(str)
    out = IOBuffer()
    i = 1
    while !done(str, i)
        c, i = next(str, i)
        if c == '%'
            c1, i = next(str, i)
            c, i = next(str, i)
            write(out, Base.parse(UInt8, string(c1, c), 16))
        else
            write(out, c)
        end
    end
    return String(take!(out))
end

"""
Splits the path into components
See: http://tools.ietf.org/html/rfc3986#section-3.3
"""
function splitpath(uri::URI, starting=2)
    elems = String[]
    p = path(uri)
    len = length(p)
    len > 1 || return elems
    start_ind = i = ifelse(p[1] == '/', 2, 1)
    while true
        c = p[i]
        if c == '/'
            push!(elems, p[start_ind:i-1])
            start_ind = i + 1
        elseif i == len
            push!(elems, p[start_ind:i])
        end
        i += 1
        (i > len || c in ('?', '#')) && break
    end
    return elems
end

# url parsing
function parseurlchar(s, ch::Char, strict::Bool)
    @anyeq(ch, ' ', '\r', '\n') && return s_dead
    strict && (ch == '\t' || ch == '\f') && return s_dead

    if s == s_req_spaces_before_url
        (ch == '/' || ch == '*') && return s_req_path
        isalpha(ch) && return s_req_schema
    elseif s == s_req_schema
        isalphanum(ch) && return s
        ch == ':' && return s_req_schema_slash
    elseif s == s_req_schema_slash
        ch == '/' && return s_req_schema_slash_slash
        isurlchar(ch) && return s_req_path
    elseif s == s_req_schema_slash_slash
        ch == '/' && return s_req_server_start
        isurlchar(ch) && return s_req_path
    elseif s == s_req_server_with_at
        ch == '@' && return s_dead
        ch == '/' && return s_req_path
        ch == '?' && return s_req_query_string_start
        (isuserinfochar(ch) || ch == '[' || ch == ']') && return s_req_server
    elseif s == s_req_server_start || s == s_req_server
        ch == '/' && return s_req_path
        ch == '?' && return s_req_query_string_start
        ch == '@' && return s_req_server_with_at
        (isuserinfochar(ch) || ch == '[' || ch == ']') && return s_req_server
    elseif s == s_req_path
        (isurlchar(ch) || ch == '@') && return s
        ch == '?' && return s_req_query_string_start
        ch == '#' && return s_req_fragment_start
    elseif s == s_req_query_string_start || s == s_req_query_string
        isurlchar(ch) && return s_req_query_string
        ch == '?' && return s_req_query_string
        ch == '#' && return s_req_fragment_start
    elseif s == s_req_fragment_start
        isurlchar(ch) && return s_req_fragment
        ch == '?' && return s_req_fragment
        ch == '#' && return s
    elseif s == s_req_fragment
        isurlchar(ch) && return s
        (ch == '?' || ch == '#') && return s
    end
    #= We should never fall out of the switch above unless there's an error =#
    return s_dead;
end

function http_parse_host_char(s::http_host_state, ch)
    if s == s_http_userinfo || s == s_http_userinfo_start
        ch == '@' && return s_http_host_start
        isuserinfochar(ch) && return s_http_userinfo
    elseif s == s_http_host_start
        ch == '[' && return s_http_host_v6_start
        ishostchar(ch) && return s_http_host
    elseif s == s_http_host
        ishostchar(ch) && return s_http_host
        ch == ':' && return s_http_host_port_start
    elseif s == s_http_host_v6_end
        ch == ':' && return s_http_host_port_start
    elseif s == s_http_host_v6
        ch == ']' && return s_http_host_v6_end
        (ishex(ch) || ch == ':' || ch == '.') && return s_http_host_v6
        s == s_http_host_v6 && ch == '%' && return s_http_host_v6_zone_start
    elseif s == s_http_host_v6_start
        (ishex(ch) || ch == ':' || ch == '.') && return s_http_host_v6
        s == s_http_host_v6 && ch == '%' && return s_http_host_v6_zone_start
    elseif s == s_http_host_v6_zone
        ch == ']' && return s_http_host_v6_end
        (isalphanum(ch) || @anyeq(ch, '%', '.', '-', '_', '~')) && return s_http_host_v6_zone
    elseif s == s_http_host_v6_zone_start
        (isalphanum(ch) || @anyeq(ch, '%', '.', '-', '_', '~')) && return s_http_host_v6_zone
    elseif s == s_http_host_port || s == s_http_host_port_start
        isnum(ch) && return s_http_host_port
    end
    return s_http_host_dead
end

function http_parse_host(buf, host::Offset, foundat)
    portoff = portlen = uioff = uilen = UInt16(0)
    off = len = UInt16(0)
    s = ifelse(foundat, s_http_userinfo_start, s_http_host_start)

    for i = host.off:(host.off + host.len - 0x0001)
        p = Char(buf[i])
        new_s = http_parse_host_char(s, p)
        new_s == s_http_host_dead && throw(ParsingError("encountered invalid host character: \n$(String(buf))\n$(lpad("", i-1, "-"))^"))
        if new_s == s_http_host
            if s != s_http_host
                off = i
            end
            len += 0x0001

        elseif new_s == s_http_host_v6
            if s != s_http_host_v6
                off = i
            end
            len += 0x0001

        elseif new_s == s_http_host_v6_zone_start || new_s == s_http_host_v6_zone
            len += 0x0001

        elseif new_s == s_http_host_port
            if s != s_http_host_port
                portoff = i
                portlen = 0x0000
            end
            portlen += 0x0001

        elseif new_s == s_http_userinfo
            if s != s_http_userinfo
                uioff = i
                uilen = 0x0000
            end
            uilen += 0x0001
        end
        s = new_s
    end
    if @anyeq(s, s_http_host_start, s_http_host_v6_start, s_http_host_v6, s_http_host_v6_zone_start,
             s_http_host_v6_zone, s_http_host_port_start, s_http_userinfo, s_http_userinfo_start)
        throw(ParsingError("ended in unexpected parsing state: $s"))
    end
    # (host, port, userinfo)
    return Offset(off, len), Offset(portoff, portlen), Offset(uioff, uilen)
end

function http_parser_parse_url(buf, startind=1, buflen=length(buf), isconnect::Bool=false)
    s = ifelse(isconnect, s_req_server_start, s_req_spaces_before_url)
    old_uf = UF_MAX
    off = len = 0
    foundat = false
    offsets = Offset[Offset(), Offset(), Offset(), Offset(), Offset(), Offset(), Offset()]
    mask = 0x00
    for i = startind:(startind + buflen - 1)
        @inbounds p = Char(buf[i])
        olds = s
        s = parseurlchar(s, p, false)
        if s == s_dead
            throw(ParsingError("encountered invalid url character for parsing state = $(ParsingStateCode(olds)): \n$(String(buf))\n$(lpad("", i-1, "-"))^"))
        elseif @anyeq(s, s_req_schema_slash, s_req_schema_slash_slash, s_req_server_start, s_req_query_string_start, s_req_fragment_start)
            continue
        elseif s == s_req_schema
            uf = UF_SCHEME
            mask |= UF_SCHEME_MASK
        elseif s == s_req_server_with_at
            foundat = true
            uf = UF_HOSTNAME
            mask |= UF_HOSTNAME_MASK
        elseif s == s_req_server
            uf = UF_HOSTNAME
            mask |= UF_HOSTNAME_MASK
        elseif s == s_req_path
            uf = UF_PATH
            mask |= UF_PATH_MASK
        elseif s == s_req_query_string
            uf = UF_QUERY
            mask |= UF_QUERY_MASK
        elseif s == s_req_fragment
            uf = UF_FRAGMENT
            mask |= UF_FRAGMENT_MASK
        else
            throw(ParsingError("ended in unexpected parsing state: $s"))
        end
        if uf == old_uf
            len += 1
            continue
        end
        if old_uf != UF_MAX
            offsets[old_uf] = Offset(off, len)
        end
        off = i
        len = 1
        old_uf = uf
    end
    if old_uf != UF_MAX
        offsets[old_uf] = Offset(off, len)
    end
    check = ~(UF_HOSTNAME_MASK | UF_PATH_MASK)
    if (mask & UF_SCHEME_MASK > 0) && (mask | check == check)
        throw(ParsingError("URI must include host or path with scheme"))
    end
    if mask & UF_HOSTNAME_MASK > 0
        host, port, userinfo = http_parse_host(buf, offsets[UF_HOSTNAME], foundat)
        if !isempty(host)
            offsets[UF_HOSTNAME] = host
            mask |= UF_HOSTNAME_MASK
        end
        if !isempty(port)
            offsets[UF_PORT] = port
            mask |= UF_PORT_MASK
        end
        if !isempty(userinfo)
            offsets[UF_USERINFO] = userinfo
            mask |= UF_USERINFO_MASK
        end
    end
    # CONNECT requests can only contain "hostname:port"
    if isconnect
        chk = HTTP.UF_HOSTNAME_MASK | HTTP.UF_PORT_MASK
        ((mask | chk) > chk) && throw(ParsingError("connect requests must contain and can only contain both hostname and port"))
    end
    return URI(buf, (offsets[UF_SCHEME],
                     offsets[UF_HOSTNAME],
                     offsets[UF_PORT],
                     offsets[UF_PATH],
                     offsets[UF_QUERY],
                     offsets[UF_FRAGMENT],
                     offsets[UF_USERINFO]))
end
