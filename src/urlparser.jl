include("consts.jl")
include("parseutils.jl")

struct URLParsingError <: Exception
    msg::String
end
Base.show(io::IO, p::URLParsingError) = println(io, "HTTP.URLParsingError: ", p.msg)

@enum(http_host_state,
    s_http_host_dead,
    s_http_userinfo_start,
    s_http_userinfo,
    s_http_host_start,
    s_http_host_v6_start,
    s_http_host,
    s_http_host_v6,
    s_http_host_v6_end,
    s_http_host_v6_zone_start,
    s_http_host_v6_zone,
    s_http_host_port_start,
    s_http_host_port,
)

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

const normal_url_char = Bool[
#=   0 nul    1 soh    2 stx    3 etx    4 eot    5 enq    6 ack    7 bel  =#
        false,   false,   false,   false,   false,   false,   false,   false,
#=   8 bs     9 ht    10 nl    11 vt    12 np    13 cr    14 so    15 si   =#
        false,   true,   false,   false,   true,   false,   false,   false,
#=  16 dle   17 dc1   18 dc2   19 dc3   20 dc4   21 nak   22 syn   23 etb =#
        false,   false,   false,   false,   false,   false,   false,   false,
#=  24 can   25 em    26 sub   27 esc   28 fs    29 gs    30 rs    31 us  =#
        false,   false,   false,   false,   false,   false,   false,   false,
#=  32 sp    33  !    34  "    35  #    36  $    37  %    38  &    39  '  =#
        false,   true,   true,   false,   true,   true,   true,  true,
#=  40  (    41  )    42  *    43  +    44  ,    45  -    46  .    47  /  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#=  48  0    49  1    50  2    51  3    52  4    53  5    54  6    55  7  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#=  56  8    57  9    58  :    59  ;    60  <    61  =    62  >    63  ?  =#
        true,   true,   true,   true,   true,   true,   true,   false,
#=  64  @    65  A    66  B    67  C    68  D    69  E    70  F    71  G  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#=  72  H    73  I    74  J    75  K    76  L    77  M    78  N    79  O  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#=  80  P    81  Q    82  R    83  S    84  T    85  U    86  V    87  W  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#=  88  X    89  Y    90  Z    91  [    92  \    93  ]    94  ^    95  _  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#=  96  `    97  a    98  b    99  c   100  d   101  e   102  f   103  g  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#= 104  h   105  i   106  j   107  k   108  l   109  m   110  n   111  o  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#= 112  p   113  q   114  r   115  s   116  t   117  u   118  v   119  w  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#= 120  x   121  y   122  z   123  {   124,   125  }   126  ~   127 del =#
        true,   true,   true,   true,   true,   true,   true,   false,
]

@inline isurlchar(c) =  c > '\u80' ? true : normal_url_char[Int(c) + 1]
