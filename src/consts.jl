@enum(Method,
    DELETE=0,
    GET=1,
    HEAD=2,
    POST=3,
    PUT=4,
    # pathological
    CONNECT=5,
    OPTIONS=6,
    TRACE=7,
    # WebDAV
    COPY=8,
    LOCK=9,
    MKCOL=10,
    MOVE=11,
    PROPFIND=12,
    PROPPATCH=13,
    SEARCH=14,
    UNLOCK=15,
    BIND=16,
    REBIND=17,
    UNBIND=18,
    ACL=19,
    # subversion
    REPORT=20,
    MKACTIVITY=21,
    CHECKOUT=22,
    MERGE=23,
    # upnp
    MSEARCH=24,
    NOTIFY=25,
    SUBSCRIBE=26,
    UNSUBSCRIBE=27,
    # RFC-5789
    PATCH=28,
    PURGE=29,
    # CalDAV
    MKCALENDAR=30,
    # RFC-2068, section 19.6.1.2
    LINK=31,
    UNLINK=32,
    xHTTP,
    NOMETHOD
)

const MethodMap = Dict(
    "HTTP" => xHTTP,
    "DELETE" => DELETE,
    "GET" => GET,
    "HEAD" => HEAD,
    "POST" => POST,
    "PUT" => PUT,
    "CONNECT" => CONNECT,
    "OPTIONS" => OPTIONS,
    "TRACE" => TRACE,
    "COPY" => COPY,
    "LOCK" => LOCK,
    "MKCOL" => MKCOL,
    "MOVE" => MOVE,
    "PROPFIND" => PROPFIND,
    "PROPPATCH" => PROPPATCH,
    "SEARCH" => SEARCH,
    "UNLOCK" => UNLOCK,
    "BIND" => BIND,
    "REBIND" => REBIND,
    "UNBIND" => UNBIND,
    "ACL" => ACL,
    "REPORT" => REPORT,
    "MKACTIVITY" => MKACTIVITY,
    "CHECKOUT" => CHECKOUT,
    "MERGE" => MERGE,
    "MSEARCH" => MSEARCH,
    "NOTIFY" => NOTIFY,
    "SUBSCRIBE" => SUBSCRIBE,
    "UNSUBSCRIBE" => UNSUBSCRIBE,
    "PATCH" => PATCH,
    "PURGE" => PURGE,
    "MKCALENDAR" => MKCALENDAR,
    "LINK" => LINK,
    "UNLINK" => UNLINK,
)
Base.convert(::Type{Method}, s::String) = MethodMap[s]

# parsing codes
@enum(ParsingErrorCode,
    HPE_OK,
    HPE_INVALID_VERSION,
    HPE_INVALID_STATUS,
    HPE_INVALID_METHOD,
    HPE_INVALID_URL,
    HPE_LF_EXPECTED,
    HPE_INVALID_HEADER_TOKEN,
    HPE_INVALID_CONTENT_LENGTH,
    HPE_UNEXPECTED_CONTENT_LENGTH,
    HPE_INVALID_CHUNK_SIZE,
    HPE_INVALID_CONSTANT,
    HPE_INVALID_INTERNAL_STATE,
    HPE_STRICT,
    HPE_UNKNOWN,
)

const ParsingErrorCodeMap = Dict(
    HPE_OK => "success",
    HPE_INVALID_VERSION => "invalid HTTP version",
    HPE_INVALID_STATUS => "invalid HTTP status code",
    HPE_INVALID_METHOD => "invalid HTTP method",
    HPE_INVALID_URL => "invalid URL",
    HPE_LF_EXPECTED => "LF character expected",
    HPE_INVALID_HEADER_TOKEN => "invalid character in header",
    HPE_INVALID_CONTENT_LENGTH => "invalid character in content-length header",
    HPE_UNEXPECTED_CONTENT_LENGTH => "unexpected content-length header",
    HPE_INVALID_CHUNK_SIZE => "invalid character in chunk size header",
    HPE_INVALID_CONSTANT => "invalid constant string",
    HPE_INVALID_INTERNAL_STATE => "encountered unexpected internal state",
    HPE_STRICT => "strict mode assertion failed",
    HPE_UNKNOWN => "an unknown error occurred",
)

# parsing state codes
@enum(ParsingStateCode
    ,es_dead=1
    ,es_start_req_or_res=2
    ,es_res_or_resp_H=3
    ,es_res_first_http_major=9
    ,es_res_http_major=10
    ,es_res_first_http_minor=11
    ,es_res_http_minor=12
    ,es_res_first_status_code=13
    ,es_res_status_code=14
    ,es_res_status_start=15
    ,es_res_status=16
    ,es_res_line_almost_done=17
    ,es_start_req=18
    ,es_req_method=19
    ,es_req_spaces_before_url=20
    ,es_req_url_start=21
    ,es_req_schema=22
    ,es_req_schema_slash
    ,es_req_schema_slash_slash
    ,es_req_server_start
    ,es_req_server
    ,es_req_server_with_at
    ,es_req_path
    ,es_req_query_string_start
    ,es_req_query_string
    ,es_req_fragment_start
    ,es_req_fragment
    ,es_req_http_start
    ,es_req_http_H
    ,es_req_http_HT
    ,es_req_http_HTT
    ,es_req_http_HTTP
    ,es_req_first_http_major
    ,es_req_http_major
    ,es_req_first_http_minor
    ,es_req_http_minor
    ,es_req_line_almost_done
    ,es_trailer_start
    ,es_header_field_start
    ,es_header_field
    ,es_header_value_discard_ws
    ,es_header_value_discard_ws_almost_done
    ,es_header_value_discard_lws
    ,es_header_value_start
    ,es_header_value
    ,es_header_value_lws
    ,es_header_almost_done
    ,es_headers_almost_done
    ,es_headers_done
    ,es_body_start
    ,es_chunk_size_start
    ,es_chunk_size
    ,es_chunk_parameters
    ,es_chunk_size_almost_done
    ,es_chunk_data
    ,es_chunk_data_almost_done
    ,es_chunk_data_done
    ,es_body_identity
    ,es_body_identity_eof
    ,es_message_done
)
for i in instances(ParsingStateCode)
    @eval const $(Symbol(string(i)[2:end])) = UInt8($i)
end

const CR = '\r'
const bCR = UInt8('\r')
const LF = '\n'
const bLF = UInt8('\n')
const CRLF = "\r\n"

#= Tokens as defined by rfc 2616. Also lowercases them.
 #        token       = 1*<any CHAR except CTLs or separators>
 #     separators     = "(" | ")" | "<" | ">" | "@"
 #                    | "," | ";" | ":" | "\" | <">
 #                    | "/" | "[" | "]" | "?" | "="
 #                    | "{" | "}" | SP | HT
 =#
const tokens = Char[
#=   0 nul    1 soh    2 stx    3 etx    4 eot    5 enq    6 ack    7 bel  =#
        0,       0,       0,       0,       0,       0,       0,       0,
#=   8 bs     9 ht    10 nl    11 vt    12 np    13 cr    14 so    15 si   =#
        0,       0,       0,       0,       0,       0,       0,       0,
#=  16 dle   17 dc1   18 dc2   19 dc3   20 dc4   21 nak   22 syn   23 etb =#
        0,       0,       0,       0,       0,       0,       0,       0,
#=  24 can   25 em    26 sub   27 esc   28 fs    29 gs    30 rs    31 us  =#
        0,       0,       0,       0,       0,       0,       0,       0,
#=  32 sp    33  !    34  "    35  #    36  $    37  %    38  &    39  '  =#
        0,      '!',      0,      '#',     '$',     '%',     '&',    '\'',
#=  40  (    41  )    42  *    43  +    44  ,    45  -    46  .    47  /  =#
        0,       0,      '*',     '+',      0,      '-',     '.',      0,
#=  48  0    49  1    50  2    51  3    52  4    53  5    54  6    55  7  =#
       '0',     '1',     '2',     '3',     '4',     '5',     '6',     '7',
#=  56  8    57  9    58  :    59  ;    60  <    61  =    62  >    63  ?  =#
       '8',     '9',      0,       0,       0,       0,       0,       0,
#=  64  @    65  A    66  B    67  C    68  D    69  E    70  F    71  G  =#
        0,      'a',     'b',     'c',     'd',     'e',     'f',     'g',
#=  72  H    73  I    74  J    75  K    76  L    77  M    78  N    79  O  =#
       'h',     'i',     'j',     'k',     'l',     'm',     'n',     'o',
#=  80  P    81  Q    82  R    83  S    84  T    85  U    86  V    87  W  =#
       'p',     'q',     'r',     's',     't',     'u',     'v',     'w',
#=  88  X    89  Y    90  Z    91  [    92  \    93  ]    94  ^    95  _  =#
       'x',     'y',     'z',      0,       0,       0,      '^',     '_',
#=  96  `    97  a    98  b    99  c   100  d   101  e   102  f   103  g  =#
       '`',     'a',     'b',     'c',     'd',     'e',     'f',     'g',
#= 104  h   105  i   106  j   107  k   108  l   109  m   110  n   111  o  =#
       'h',     'i',     'j',     'k',     'l',     'm',     'n',     'o',
#= 112  p   113  q   114  r   115  s   116  t   117  u   118  v   119  w  =#
       'p',     'q',     'r',     's',     't',     'u',     'v',     'w',
#= 120  x   121  y   122  z   123  {   124  |   125  }   126  ~   127 del =#
       'x',     'y',     'z',      0,      '|',      0,      '~',       0 ]

istoken(c) = tokens[UInt8(c)+1] != Char(0)

const unhex = Int8[
     -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
    ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
    ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
    , 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,-1,-1,-1,-1,-1,-1
    ,-1,10,11,12,13,14,15,-1,-1,-1,-1,-1,-1,-1,-1,-1
    ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
    ,-1,10,11,12,13,14,15,-1,-1,-1,-1,-1,-1,-1,-1,-1
    ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
]

# url parsing
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

@enum(http_host_state,
    s_http_host_dead = 1,
    s_http_userinfo_start =2,
    s_http_userinfo = 3,
    s_http_host_start = 4,
    s_http_host_v6_start = 5,
    s_http_host = 6,
    s_http_host_v6,
    s_http_host_v6_end,
    s_http_host_v6_zone_start,
    s_http_host_v6_zone,
    s_http_host_port_start,
    s_http_host_port,
)
