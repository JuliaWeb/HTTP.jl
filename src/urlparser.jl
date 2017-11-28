include("consts.jl")
include("utils.jl")

struct URLParsingError <: Exception
    msg::String
end
Base.show(io::IO, p::URLParsingError) = println("HTTP.URLParsingError: ", p.msg)

struct Offset
    off::UInt16
    len::UInt16
end
Offset() = Offset(0, 0)
Base.getindex(A::Vector{UInt8}, o::Offset) = A[o.off:(o.off + o.len - 1)]
Base.isempty(o::Offset) = o.off == 0x0000 && o.len == 0x0000
==(a::Offset, b::Offset) = a.off == b.off && a.len == b.len
const EMPTYOFFSET = Offset()

@enum(http_parser_url_fields,
      UF_SCHEME   = 1
    , UF_HOSTNAME = 2
    , UF_PORT     = 3
    , UF_PATH     = 4
    , UF_QUERY    = 5
    , UF_FRAGMENT = 6
    , UF_USERINFO = 7
    , UF_MAX      = 8
)
const UF_SCHEME_MASK = 0x01
const UF_HOSTNAME_MASK = 0x02
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
        new_s == s_http_host_dead && throw(URLParsingError("encountered invalid host character: \n$(String(buf))\n$(lpad("", i-1, "-"))^"))
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
        throw(URLParsingError("ended in unexpected parsing state: $s"))
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
            throw(URLParsingError("encountered invalid url character for parsing state = $(ParsingStateCode(olds)): \n$(String(buf))\n$(lpad("", i-1, "-"))^"))
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
            throw(URLParsingError("ended in unexpected parsing state: $s"))
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
        throw(URLParsingError("URI must include host or path with scheme"))
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
        chk = UF_HOSTNAME_MASK | UF_PORT_MASK
        ((mask | chk) > chk) && throw(URLParsingError("connect requests must contain and can only contain both hostname and port"))
    end
    return URI(buf, (offsets[UF_SCHEME],
                     offsets[UF_HOSTNAME],
                     offsets[UF_PORT],
                     offsets[UF_PATH],
                     offsets[UF_QUERY],
                     offsets[UF_FRAGMENT],
                     offsets[UF_USERINFO]))
end
