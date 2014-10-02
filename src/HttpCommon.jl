module HttpCommon

if VERSION < v"0.4-"
    using Dates
else
    using Base.Dates
end

export STATUS_CODES,
       GET,
       POST,
       PUT,
       UPDATE,
       DELETE,
       OPTIONS,
       HEAD,
       RFC1123_datetime,
       HttpMethodBitmask,
       HttpMethodBitmasks,
       HttpMethodNameToBitmask,
       HttpMethodBitmaskToName,
       Headers,
       Request,
       Response,
       escapeHTML,
       encodeURI,
       decodeURI,
       parsequerystring,
       FileResponse,
       mimetypes

include("mimetypes.jl")

import Base.show

const STATUS_CODES = {
    100 => "Continue",
    101 => "Switching Protocols",
    102 => "Processing",                          # RFC 2518, obsoleted by RFC 4918
    200 => "OK",
    201 => "Created",
    202 => "Accepted",
    203 => "Non-Authoritative Information",
    204 => "No Content",
    205 => "Reset Content",
    206 => "Partial Content",
    207 => "Multi-Status",                        # RFC 4918
    300 => "Multiple Choices",
    301 => "Moved Permanently",
    302 => "Moved Temporarily",
    303 => "See Other",
    304 => "Not Modified",
    305 => "Use Proxy",
    307 => "Temporary Redirect",
    400 => "Bad Request",
    401 => "Unauthorized",
    402 => "Payment Required",
    403 => "Forbidden",
    404 => "Not Found",
    405 => "Method Not Allowed",
    406 => "Not Acceptable",
    407 => "Proxy Authentication Required",
    408 => "Request Time-out",
    409 => "Conflict",
    410 => "Gone",
    411 => "Length Required",
    412 => "Precondition Failed",
    413 => "Request Entity Too Large",
    414 => "Request-URI Too Large",
    415 => "Unsupported Media Type",
    416 => "Requested Range Not Satisfiable",
    417 => "Expectation Failed",
    418 => "I'm a teapot",                        # RFC 2324
    422 => "Unprocessable Entity",                # RFC 4918
    423 => "Locked",                              # RFC 4918
    424 => "Failed Dependency",                   # RFC 4918
    425 => "Unordered Collection",                # RFC 4918
    426 => "Upgrade Required",                    # RFC 2817
    428 => "Precondition Required",               # RFC 6585
    429 => "Too Many Requests",                   # RFC 6585
    431 => "Request Header Fields Too Large",     # RFC 6585
    500 => "Internal Server Error",
    501 => "Not Implemented",
    502 => "Bad Gateway",
    503 => "Service Unavailable",
    504 => "Gateway Time-out",
    505 => "HTTP Version Not Supported",
    506 => "Variant Also Negotiates",             # RFC 2295
    507 => "Insufficient Storage",                # RFC 4918
    509 => "Bandwidth Limit Exceeded",
    510 => "Not Extended",                        # RFC 2774
    511 => "Network Authentication Required"      # RFC 6585
}

# HTTP method bitmasks and indexes, allow for fancy GET | POST | UPDATE style APIs.
typealias HttpMethodBitmask Int

const HttpMethodBitmasks = HttpMethodBitmask[
    (const GET     = 2^0),
    (const POST    = 2^1),
    (const PUT     = 2^2),
    (const UPDATE  = 2^3),
    (const DELETE  = 2^4),
    (const OPTIONS = 2^5),
    (const HEAD    = 2^6)
]

const HttpMethodNameToBitmask = (String => HttpMethodBitmask)[
    "GET"     => GET,
    "POST"    => POST,
    "PUT"     => PUT,
    "UPDATE"  => UPDATE,
    "DELETE"  => DELETE,
    "OPTIONS" => OPTIONS,
    "HEAD"    => HEAD
]

const HttpMethodBitmaskToName = (HttpMethodBitmask => String)[v => k for (k, v) in HttpMethodNameToBitmask]

# Get RFC 1123 datetimes
#
#     RFC1123_datetime( now() ) => "Wed, 27 Mar 2013 08:26:04 GMT"
#     RFC1123_datetime()        => "Wed, 27 Mar 2013 08:26:04 GMT"
#
RFC1123_datetime(t::DateTime) = begin
    Dates.format(t, Dates.RFC1123Format) * " GMT"
end
RFC1123_datetime() = RFC1123_datetime(Dates.now(Dates.UTC))

# HTTP Headers
#
# Dict Type for HTTP headers
# `headers()` for building default Response Headers
#
typealias Headers Dict{String,String}
headers() = (String => String)[ "Server" => "Julia/$VERSION",
                                "Content-Type" => "text/html; charset=utf-8",
                                "Content-Language" => "en",
                                "Date" => RFC1123_datetime()]

# HTTP request
#
# - method   => valid HTTP method string (e.g. "GET")
# - resource => requested resource (e.g. "/hello/world")
# - headers  => HTTP headers
# - data     => request data
# - state    => used to store various data during request processing
#
type Request
    method::String
    resource::String
    headers::Headers
    data::String
end
Request() = Request("", "", (String=>String)[], "")

# HTTP response
#
# - status   => HTTP status code (see: `STATUS_CODES`)
# - headers  => HTTP headers
# - data     => response data
# - finished => indicates that a Response is "valid" and can be converted to an
#               actual HTTP response
#
# If a Response is instantiated with all of these attributes except for
# `finished`, `finished` will default to `false`.
#
# A Response can also be instantiated with an HTTP status code, in which case
# sane defaults will be set:
#
#     Response(200)
#     # => Response(200, "OK", ["Server" => "v\"0.2.0-740.r6df6\""], "200 OK", false)
#
typealias HttpData Union(String,Array{Uint8})
type Response
    status::Int
    headers::Headers
    data::HttpData
    finished::Bool
end
Response(s::Int, h::Headers, d::HttpData) = Response(s, h, d, false)
Response(s::Int, h::Headers)            = Response(s, h, "", false)
Response(s::Int, d::HttpData)             = Response(s, headers(), d, false)
Response(d::HttpData, h::Headers)         = Response(200, h, d, false)
Response(d::HttpData)                     = Response(200, headers(), d,false)
Response(s::Int)                        = Response(s, headers(), "", false)
Response()                              = Response(200)

show(io::IO,r::Response) = print(io,"Response(",r.status," ",STATUS_CODES[r.status],", ",length(r.headers)," Headers, ",sizeof(r.data)," Bytes in Body)")

function FileResponse(filename)
    if isfile(filename)
        s = open(readbytes,filename)
        (_, ext) = splitext(filename)
        mime = length(ext)>1 && haskey(mimetypes,ext[2:end]) ? mimetypes[ext[2:end]] : "application/octet-stream"
        Response(200, Dict{String,String}({"Content-Type"},{mime}), s)
    else
        Response(404, "Not Found - file $filename could not be found")
    end         
end

# Escape HTML characters
#
# Safety first!
#
function escapeHTML(i::String)
    o = replace(i, r"&(?!(\w+|\#\d+);)", "&amp;")
    o = replace(o, "<", "&lt;")
    o = replace(o, ">", "&gt;")
    replace(o, "\"", "&quot;")
end

# All characters that remain unencoded in URI encoding
#                                   ( AKA URL encoding
#                                     AKA percent-encoding )
#
const URIwhitelist = Set('A','B','C','D','E','F','G','H','I',
                         'J','K','L','M','N','O','P','Q','R',
                         'S','T','U','V','W','X','Y','Z',
                         'a','b','c','d','e','f','g','h','i',
                         'j','k','l','m','n','o','p','q','r',
                         's','t','u','v','w','x','y','z',
                         '0','1','2','3','4','5','6','7','8',
                         '9','-','_','.','~')

# decodeURI
#
# Decode URI encoded strings
#
function decodeURI(encoded::String)
    enc = split(replace(encoded,"+"," "),"%")
    decoded = enc[1]
    for c in enc[2:end]
        decoded = string(decoded, char(parseint(c[1:2],16)), c[3:end])
    end
    decoded
end

# encodeURI
#
# Convert strings to URI encoding
#
function encodeURI(decoded::String)
    encoded = ""
    for c in decoded
        encoded = encoded * string(c in URIwhitelist ? c : "%" * uppercase(hex(int(c))))
    end
    encoded
end

# parsequerystring
#
# Convert a valid querystring to a Dict:
#
#    q = "foo=bar&baz=%3Ca%20href%3D%27http%3A%2F%2Fwww.hackershool.com%27%3Ehello%20world%21%3C%2Fa%3E"
#    parsequerystring(q)
#    # => ["foo"=>"bar","baz"=>"<a href='http://www.hackershool.com'>hello world!</a>"]
#
function parsequerystring(query::String)
    q = Dict{String,String}()
    if !('=' in query)
        return throw("Not a valid query string: $query, must contain at least one key=value pair.")
    end
    for set in split(query, "&")
        key, val = split(set, "=")
        q[decodeURI(key)] = decodeURI(val)
    end
    q
end


end # module Httplib
