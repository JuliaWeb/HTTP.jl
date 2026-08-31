include("consts.jl")
include("parseutils.jl")

struct URLParsingError <: Exception
    msg::String
end
Base.show(io::IO, p::URLParsingError) = println(io, "HTTP.URLParsingError: ", p.msg)

@enum(http_parser_url_fields,
      UF_SCHEME   = 1
    , UF_HOST     = 2
    , UF_PORT     = 3
    , UF_PATH     = 4
    , UF_QUERY    = 5
    , UF_FRAGMENT = 6
    , UF_USERINFO = 7
    , UF_MAX      = 8
)
const UF_SCHEME_MASK = 0x01
const UF_HOST_MASK = 0x02
const UF_PORT_MASK = 0x04
const UF_PATH_MASK = 0x08
const UF_QUERY_MASK = 0x10
const UF_FRAGMENT_MASK = 0x20
const UF_USERINFO_MASK = 0x40

@inline function Base.getindex(A::Vector{T}, i::http_parser_url_fields) where {T}
    @inbounds v = A[Int(i)]
    return v
end
@inline function Base.setindex!(A::Vector{T}, v::T, i::http_parser_url_fields) where {T}
    @inbounds v = setindex!(A, v, Int(i))
    return v
end

# url parsing
function parseurlchar(s, ch::Char, strict::Bool)
    @anyeq(ch, ' ', '\r', '\n') && return s_dead
    strict && (ch == '\t' || ch == '\f') && return s_dead

    if s == s_req_spaces_before_url || s == s_req_url_start
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
    return s_dead
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

function http_parse_host(host::SubString, foundat)

    host1 = port1 = userinfo1 = 1
    host2 = port2 = userinfo2 = 0
    s = ifelse(foundat, s_http_userinfo_start, s_http_host_start)

    for i in eachindex(host)
        @inbounds p = host[i]

        new_s = http_parse_host_char(s, p)
        if new_s == s_http_host_dead 
            throw(URLParsingError("encountered invalid host character: \n" *
                                  "$host\n$(lpad("", i-1, "-"))^"))
        end
        if new_s == s_http_host
            if s != s_http_host
                host1 = i
            end
            host2 = i

        elseif new_s == s_http_host_v6
            if s != s_http_host_v6
                host1 = i
            end
            host2 = i

        elseif new_s == s_http_host_v6_zone_start ||
               new_s == s_http_host_v6_zone
            host2 = i

        elseif new_s == s_http_host_port
            if s != s_http_host_port
                port1 = i
            end
            port2 = i

        elseif new_s == s_http_userinfo
            if s != s_http_userinfo
                userinfo1 = i
            end
            userinfo2 = i
        end
        s = new_s
    end
    if @anyeq(s, s_http_host_start, s_http_host_v6_start, s_http_host_v6,
                 s_http_host_v6_zone_start, s_http_host_v6_zone,
                 s_http_host_port_start, s_http_userinfo, s_http_userinfo_start)
        throw(URLParsingError("ended in unexpected parsing state: $s"))
    end

    return SubString(host, host1, host2),
           SubString(host, port1, port2),
           SubString(host, userinfo1, userinfo2)
end


function http_parser_parse_url(url::AbstractString, isconnect::Bool=false)

    s = ifelse(isconnect, s_req_server_start, s_req_spaces_before_url)
    old_uf = UF_MAX
    off1 = off2 = 0
    foundat = false

    empty = SubString(url, 1, 0)
    parts = [empty, empty, empty, empty, empty, empty, empty]

    mask = 0x00
    for i in eachindex(url)
        @inbounds p = url[i]
        olds = s
        s = parseurlchar(s, p, false)
        if s == s_dead
            throw(URLParsingError(
                "encountered invalid url character for parsing state = " *
                "$(ParsingStateCode(olds)):\n$url)\n$(lpad("", i-1, "-"))^"))
        elseif @anyeq(s, s_req_schema_slash,
                         s_req_schema_slash_slash,
                         s_req_server_start,
                         s_req_query_string_start,
                         s_req_fragment_start)
            continue
        elseif s == s_req_schema
            uf = UF_SCHEME
            mask |= UF_SCHEME_MASK
        elseif s == s_req_server_with_at
            foundat = true
            uf = UF_HOST
            mask |= UF_HOST_MASK
        elseif s == s_req_server
            uf = UF_HOST
            mask |= UF_HOST_MASK
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
            throw(URLParsingError("ended in unexpected parsing state: $s"))
        end
        if uf == old_uf
            off2 = i
            continue
        end
        if old_uf != UF_MAX
            parts[old_uf] = SubString(url, off1, off2)
        end
        off1 = i
        off2 = i
        old_uf = uf
    end
    if old_uf != UF_MAX
        parts[old_uf] = SubString(url, off1, off2)
    end
    check = ~(UF_HOST_MASK | UF_PATH_MASK)
    if (mask & UF_SCHEME_MASK > 0) && (mask | check == check)
        throw(URLParsingError("URI must include host or path with scheme"))
    end
    if mask & UF_HOST_MASK > 0
        host, port, userinfo = http_parse_host(parts[UF_HOST], foundat)
        if !isempty(host)
            parts[UF_HOST] = host
            mask |= UF_HOST_MASK
        end
        if !isempty(port)
            parts[UF_PORT] = port
            mask |= UF_PORT_MASK
        end
        if !isempty(userinfo)
            parts[UF_USERINFO] = userinfo
            mask |= UF_USERINFO_MASK
        end
    end
    # CONNECT requests can only contain "hostname:port"
    if isconnect
        chk = UF_HOST_MASK | UF_PORT_MASK
        ((mask | chk) > chk) && throw(URLParsingError("connect requests must contain and can only contain both hostname and port"))
    end

    return URI(url, parts...)
end
