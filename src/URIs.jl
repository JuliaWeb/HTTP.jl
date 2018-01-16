module URIs

import Base.==

import ..@require, ..precondition_error
import ..@ensure, ..postcondition_error


include("urlparser.jl")

export URI,
       resource, queryparams, absuri,
       escapeuri, unescapeuri, escapepath


"""
    HTTP.URI(; scheme="", host="", port="", etc...)
    HTTP.URI(str) = parse(HTTP.URI, str::String)

A type representing a valid uri. Can be constructed from distinct parts using the various
supported keyword arguments. With a raw, already-encoded uri string, use `parse(HTTP.URI, str)`
to parse the `HTTP.URI` directly. The `HTTP.URI` constructors will automatically escape any provided
`query` arguments, typically provided as `"key"=>"value"::Pair` or `Dict("key"=>"value")`.
Note that multiple values for a single query key can provided like `Dict("key"=>["value1", "value2"])`.

The `URI` struct stores the compelte URI in the `uri::String` field and the
component parts in the following `SubString` fields:
  * `scheme`, e.g. `"http"` or `"https"`
  * `userinfo`, e.g. `"username:password"`
  * `host` e.g. `"julialang.org"`
  * `port` e.g. `"80"` or `""`
  * `path` e.g `"/"`
  * `query` e.g. `"Foo=1&Bar=2"`
  * `fragment`

The `HTTP.resource(::URI)` function returns a target-resource string for the URI
[RFC7230 5.3](https://tools.ietf.org/html/rfc7230#section-5.3).
e.g. `"\$path?\$query#\$fragment"`.

The `HTTP.queryparams(::URI)` function returns a `Dict` containing the `query`.
"""

struct URI
    uri::String
    scheme::SubString
    userinfo::SubString
    host::SubString
    port::SubString
    path::SubString
    query::SubString
    fragment::SubString
end


URI(uri::URI) = uri

const emptyuri = (()->begin
    uri = ""
    empty = SubString(uri)
    return URI(uri, empty, empty, empty, empty, empty, empty, empty)
end)()

URI(;kw...) = merge(emptyuri; kw...)

function Base.merge(uri::URI; scheme::AbstractString=uri.scheme,
                              userinfo::AbstractString=uri.userinfo,
                              host::AbstractString=uri.host,
                              port::Union{Integer,AbstractString}=uri.port,
                              path::AbstractString=uri.path,
                              query=uri.query,
                              fragment::AbstractString=uri.fragment)

    @require isempty(host) || host[end] != '/'
    @require scheme in uses_authority || isempty(host)
    @require !isempty(host) || isempty(port)
    @require !(scheme in ["http", "https"]) || isempty(path) || path[1] == '/'
    @require !isempty(path) || !isempty(query) || isempty(fragment)

    ports = string(port)
    querys = query isa String ? query : escapeuri(query)

    str = uristring(scheme, userinfo, host, ports, path, querys, fragment)
    result = parse(URI, str)

    if uri === emptyuri
        @ensure result.scheme == scheme
        @ensure result.userinfo == userinfo
        @ensure result.host == host
        @ensure result.port == ports
        @ensure result.path == path
        @ensure result.query == querys
    end

    return result
end


URI(str::AbstractString) = Base.parse(URI, str)

function Base.parse(::Type{URI}, str::AbstractString)

    uri = http_parser_parse_url(str)

    @ensure uristring(uri) == str
    return uri
end


==(a::URI,b::URI) = a.scheme      == b.scheme      &&
                    a.host        == b.host        &&
                    normalport(a) == normalport(b) &&
                    a.path        == b.path        &&
                    a.query       == b.query       &&
                    a.fragment    == b.fragment    &&
                    a.userinfo    == b.userinfo

# "request-target" per https://tools.ietf.org/html/rfc7230#section-5.3
resource(uri::URI) = string( isempty(uri.path)     ? "/" :     uri.path,
                            !isempty(uri.query)    ? "?" : "", uri.query,
                            !isempty(uri.fragment) ? "#" : "", uri.fragment)

normalport(uri::URI) = uri.scheme == "http"  && uri.port == "80" ||
                       uri.scheme == "https" && uri.port == "443" ?
                       "" : uri.port

hoststring(h) = ':' in h ? "[$h]" : h

Base.show(io::IO, uri::URI) = print(io, "HTTP.URI(\"", uri, "\")")

Base.print(io::IO, u::URI) = print(io, u.uri)

Base.string(u::URI) = u.uri

nouserinfo(ui) = isempty(ui) && !(ui === blank_userinfo)

function formaturi(io::IO,
                   scheme::AbstractString,
                   userinfo::AbstractString,
                   host::AbstractString,
                   port::AbstractString,
                   path::AbstractString,
                   query::AbstractString,
                   fragment::AbstractString)

    isempty(scheme)      || print(io, scheme, scheme in uses_authority ?
                                           "://" : ":")
    nouserinfo(userinfo) || print(io, userinfo, "@")
    isempty(host)        || print(io, hoststring(host))
    isempty(port)        || print(io, ":", port)
    isempty(path)        || print(io, path)
    isempty(query)       || print(io, "?", query)
    isempty(fragment)    || print(io, "#", fragment)

    return io
end

uristring(a...) = String(take!(formaturi(IOBuffer(), a...)))

uristring(u::URI) = uristring(u.scheme, u.userinfo, u.host, u.port,
                              u.path, u.query, u.fragment)

queryparams(uri::URI) = queryparams(uri.query)

function queryparams(q::AbstractString)
    Dict(unescapeuri(k) => unescapeuri(v)
        for (k,v) in ([split(e, "=")..., ""][1:2]
            for e in split(q, "&", keep=false)))
end


# Validate known URI formats
const uses_authority = ["https", "http", "ws", "wss", "hdfs", "ftp", "gopher", "nntp", "telnet", "imap", "wais", "file", "mms", "shttp", "snews", "prospero", "rtsp", "rtspu", "rsync", "svn", "svn+ssh", "sftp" ,"nfs", "git", "git+ssh", "ldap", "s3"]
const non_hierarchical = ["gopher", "hdl", "mailto", "news", "telnet", "wais", "imap", "snews", "sip", "sips"]
const uses_query = ["http", "wais", "imap", "https", "shttp", "mms", "gopher", "rtsp", "rtspu", "sip", "sips", "ldap"]
const uses_fragment = ["hdfs", "ftp", "hdl", "http", "gopher", "news", "nntp", "wais", "https", "shttp", "snews", "file", "prospero"]

"checks if a `HTTP.URI` is valid"
function Base.isvalid(uri::URI)
    sch = uri.scheme
    isempty(sch) && throw(ArgumentError("can not validate relative URI"))
    if ((sch in non_hierarchical) && (search(uri.path, '/') > 1)) ||       # path hierarchy not allowed
       (!(sch in uses_query) && !isempty(uri.query)) ||                    # query component not allowed
       (!(sch in uses_fragment) && !isempty(uri.fragment)) ||              # fragment identifier component not allowed
       (!(sch in uses_authority) && (!isempty(uri.host) || ("" != uri.port) || !isempty(uri.userinfo))) # authority component not allowed
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
function escapeuri end

escapeuri(c::Char) = string('%', uppercase(hex(c,2)))
escapeuri(str::AbstractString, safe::Function=issafe) =
    join(safe(c) ? c : escapeuri(c) for c in utf8_chars(str))

escapeuri(bytes::Vector{UInt8}) = bytes
escapeuri(v::Number) = escapeuri(string(v))
escapeuri(v::Symbol) = escapeuri(string(v))
@static if VERSION < v"0.7.0-DEV.3017"
escapeuri(v::Nullable) = Base.isnull(v) ? "" : escapeuri(get(v))
end

escapeuri(key, value) = string(escapeuri(key), "=", escapeuri(value))
escapeuri(key, values::Vector) = escapeuri(key => v for v in values)
escapeuri(query) = join((escapeuri(k, v) for (k,v) in query), "&")

"unescape a percent-encoded uri/url"
function unescapeuri(str)
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

ispathsafe(c::Char) = c == '/' || issafe(c)
escapepath(path) = escapeuri(path, ispathsafe)


"""
Splits the path into components
See: http://tools.ietf.org/html/rfc3986#section-3.3
"""
function splitpath(p::AbstractString)
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

function absuri(uri::URI, context::URI)

    if !isempty(uri.host)
        return uri
    end

    @assert !isempty(context.scheme)
    @assert !isempty(context.host)
    @assert isempty(uri.port)

    return merge(context; path=uri.path, query=uri.query)
end

end # module
