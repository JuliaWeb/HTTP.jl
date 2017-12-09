module URIs

import Base.==

include("urlparser.jl")

export URI, URL,
       hasscheme, scheme,
       hashostname, hostname,
       haspath, path,
       hasquery, query,
       hasfragment, fragment,
       hasuserinfo, userinfo,
       hasport, port,
       resource, host,
       escape, unescape,
       splitpath, queryparams,
       absuri

"""
    HTTP.URL(host; userinfo="", path="", query="", fragment="", isconnect=false)
    HTTP.URI(; scheme="", hostname="", port="", ...)
    HTTP.URI(str; isconnect=false)
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
  * `HTTP.host`: returns the "hostname:port" combination; if the port is not provided or is the default port for the uri scheme, it will be omitted
  * `HTTP.path`: returns the path for a uri
  * `HTTP.query`: returns the query for a uri
  * `HTTP.fragment`: returns the fragment for a uri
  * `HTTP.resource`: returns the path-query-fragment combination
"""
struct URI
#=    data::Vector{UInt8}
    offsets::NTuple{7, Offset} =#
    uri::String
    scheme::SubString
    hostname::SubString
    port::SubString
    path::SubString
    query::SubString
    fragment::SubString
    userinfo::SubString
end

function URI(;hostname::AbstractString="", path::AbstractString="",
            scheme::AbstractString="", userinfo::AbstractString="",
            port::Union{Integer,AbstractString}="", query="",
            fragment::AbstractString="", isconnect::Bool=false)
    hostname != "" && scheme == "" && !isconnect && (scheme = "http")
    io = IOBuffer()
    printuri(io, scheme, userinfo, hostname, string(port), path, escape(query), fragment)
    return URI(String(take!(io)); isconnect=isconnect)
end

# we assume `str` is at least hostname & port
# if all others keywords are empty, assume CONNECT
# can include path, userinfo, query, & fragment
function URL(str::AbstractString; userinfo::AbstractString="", path::AbstractString="",
                          query="", fragment::AbstractString="",
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

URI(str::AbstractString; isconnect::Bool=false) = Base.parse(URI, str; isconnect=isconnect)
Base.parse(::Type{URI}, str::AbstractString; isconnect::Bool=false) = http_parser_parse_url(Vector{UInt8}(str), 1, sizeof(str), isconnect)

==(a::URI,b::URI) = scheme(a)   == scheme(b)    &&
                    hostname(a) == hostname(b)  &&
                    path(a)     == path(b)      &&
                    query(a)    == query(b)     &&
                    fragment(a) == fragment(b)  &&
                    userinfo(a) == userinfo(b)  &&
                    ((!hasport(a) || !hasport(b)) || (port(a) == port(b)))
# accessors
for uf in instances(http_parser_url_fields)
    uf == UF_MAX && break
    nm = lowercase(string(uf)[4:end])
    has = Symbol(string("has", nm))
    @eval $has(uri::URI) = !isempty(uri.$(Symbol(nm)))
    uf == UF_PORT && continue
    #@eval $(Symbol(nm))(uri::URI) = String(uri.data[uri.offsets[Int($uf)]])
    @eval $(Symbol(nm))(uri::URI) = uri.$(Symbol(nm))
end

# special def for port
function port(uri::URI)
    if hasport(uri)
        return uri.port
    else
        sch = scheme(uri)
        return sch == "http" ? "80" : sch == "https" ? "443" : ""
    end
end

resource(uri::URI; isconnect::Bool=false) = isconnect ? host(uri) : path(uri) * (isempty(query(uri)) ? "" : "?$(query(uri))") * (isempty(fragment(uri)) ? "" : "#$(fragment(uri))")
function host(uri::URI)
    h = hostname(uri)
    sch = scheme(uri)
    p = uri.port
    if isempty(p) || (sch == "http" && p == "80") || (sch == "https" && p == "443")
        return h
    else
        return string(h, p)
    end
end

Base.show(io::IO, uri::URI) = print(io, "HTTP.URI(\"", uri, "\")")

Base.print(io::IO, u::URI) = printuri(io, scheme(u), userinfo(u), hostname(u), port(u), path(u), query(u), fragment(u))
function printuri(io::IO, sch::AbstractString, userinfo::AbstractString, hostname::AbstractString, port::AbstractString, path::AbstractString, query::AbstractString, fragment::AbstractString)
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
    if (isempty(hostname) || hostname[end] != '/') &&
       (isempty(path) || path[1] != '/') &&
       (!isempty(fragment) || !isempty(path))
        path = (!isempty(sch) && sch == "http" || sch == "https") ? string("/", path) : path
    end
    print(io, path, isempty(query) ? "" : "?$query", isempty(fragment) ? "" : "#$fragment")
end

queryparams(uri::URI) = queryparams(query(uri))
function queryparams(q::AbstractString)
    Dict(unescape(k) => unescape(v)
        for (k,v) in ([split(e, "=")..., ""][1:2]
            for e in split(q, "&", keep=false)))
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

# RFC3986 Unreserved Characters (and '~' Unsafe per RFC1738).
@inline issafe(c::Char) = c == '-' ||
                          c == '.' ||
                          c == '_' ||
                          (isascii(c) && isalnum(c))

utf8_chars(str::AbstractString) = (Char(c) for c in Vector{UInt8}(str))

"percent-encode a string, dict, or pair for a uri"
function escape end

escape(c::Char) = string('%', uppercase(hex(c,2)))
escape(str::AbstractString, safe::Function=issafe) = 
    join(safe(c) ? c : escape(c) for c in utf8_chars(str))

escape(bytes::Vector{UInt8}) = bytes
escape(v::Number) = escape(string(v))
escape(v::Symbol) = escape(string(v))
escape(v::Nullable) = Base.isnull(v) ? "" : escape(get(v))

escape(key, value) = string(escape(key), "=", escape(value))
escape(key, values::Vector) = escape(key => v for v in values)
escape(query) = join((escape(k, v) for (k,v) in query), "&")

"unescape a percent-encoded uri/url"
function unescape(str)
    contains(str, "%") || return str
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
function splitpath end

splitpath(uri::URI) = splitpath(path(uri))
function splitpath(p::String)
    elems = String[]
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

absuri(u, context) = absuri(URI(u), URI(context))

function absuri(u::URI, context::URI)

    @assert !isempty(hostname(context))

    s = scheme(u)
    h = hostname(u)
    n = port(u)
    p = path(u)
    q = query(u)

    return URIs.URI(scheme=isempty(s) ? scheme(context) : s,
                    hostname=isempty(h) ? hostname(context) : h,
                    port=isempty(n) ? port(context) : n,
                    path=isempty(p) ? path(context) : p,
                    query=isempty(q) ? query(context) : q)
end

end # module
