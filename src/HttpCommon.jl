__precompile__()

module HttpCommon

import URIParser: URI, unescape

export Headers,
       Request,
       Response,
       escapeHTML,
       parsequerystring,
       FileResponse

export mimetypes
include("mimetypes.jl")

# All HTTP status codes, as a Dict of code => description
export STATUS_CODES
include("status.jl")


# HTTP Headers
#
# Dict Type for HTTP headers
# `headers()` for building default Response Headers
#
typealias Headers Dict{String,String}
headers() = Dict{String,String}([
    ("Server"            , "Julia/$VERSION"),
    ("Content-Type"      , "text/html; charset=utf-8"),
    ("Content-Language"  , "en"),
    ("Date"              , Dates.format(now(Dates.UTC),Dates.RFC1123Format))
])

# HTTP request
#
# - method   => valid HTTP method string (e.g. "GET")
# - resource => requested resource (e.g. "/hello/world")
# - headers  => HTTP headers
# - data     => request data
# - state    => used to store various data during request processing

typealias HttpData Union{Vector{UInt8}, String}
asbytes(r::ByteString) = r.data
asbytes(r::String) = asbytes(bytestring(r))
asbytes(r) = convert(Vector{UInt8}, r)


type Request
    method::String
    resource::String
    headers::Headers
    data::Vector{UInt8}
    uri::URI
end
Request() = Request("", "", Dict{String,String}(), UInt8[], URI(""))
Request(method, resource, headers, data) = Request(method, resource, headers, data, URI(""))

function Base.show(io::IO, r::Request)
    print(io, "Request(")
    print(io, r.uri)
    print(io, ", ", length(r.headers), " Headers")
    print(io, ", ", sizeof(r.data), " Bytes in Body)")
end

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

type Cookie
    name::UTF8String
    value::UTF8String
    attrs::Dict{UTF8String, UTF8String}
end

Cookie(name, value) = Cookie(name, value, Dict{UTF8String, UTF8String}())

typealias Cookies Dict{UTF8String, Cookie}

type Response
    status::Int
    headers::Headers
    cookies::Cookies
    data::Vector{UInt8}
    finished::Bool
    # The history of requests that generated the response. Can be greater than
    # one if a redirect was involved.
    requests::Vector{Request}
end

Response(s::Int, h::Headers, d::HttpData) = Response(s, h, Cookies(), asbytes(d), false, Request[])
Response(s::Int, h::Headers)              = Response(s, h, UInt8[])
Response(s::Int, d::HttpData)             = Response(s, headers(), d)
Response(d::HttpData, h::Headers)         = Response(200, h, d)
Response(d::HttpData)                     = Response(d, headers())
Response(s::Int)                          = Response(s, headers(), UInt8[])
Response()                                = Response(200)



Base.show(io::IO,r::Response) = print(io,"Response(",r.status," ",STATUS_CODES[r.status],", ",length(r.headers)," Headers, ",sizeof(r.data)," Bytes in Body)")

function FileResponse(filename)
    if isfile(filename)
        s = open(readbytes,filename)
        (_, ext) = splitext(filename)
        mime = length(ext)>1 && haskey(mimetypes,ext[2:end]) ? mimetypes[ext[2:end]] : "application/octet-stream"
        Response(200, Dict{String,String}([("Content-Type",mime)]), s)
    else
        Response(404, "Not Found - file $filename could not be found")
    end
end


"""
escapeHTML(i::String)

Returns a string with special HTML characters escaped: &, <, >, ", '
"""
function escapeHTML(i::String)
    # Refer to http://stackoverflow.com/a/7382028/3822752 for spec. links
    o = replace(i, "&", "&amp;")
    o = replace(o, "\"", "&quot;")
    o = replace(o, "'", "&#39;")
    o = replace(o, "<", "&lt;")
    o = replace(o, ">", "&gt;")
    return o
end


"""
parsequerystring(query::String)

Convert a valid querystring to a Dict:

    q = "foo=bar&baz=%3Ca%20href%3D%27http%3A%2F%2Fwww.hackershool.com%27%3Ehello%20world%21%3C%2Fa%3E"
    parsequerystring(q)
    # Dict{ASCIIString,ASCIIString} with 2 entries:
    #   "baz" => "<a href='http://www.hackershool.com'>hello world!</a>"
    #   "foo" => "bar"
"""
function parsequerystring{T<:String}(query::T)
    q = Dict{T,T}()
    length(query) == 0 && return q
    for field in split(query, "&")
        keyval = split(field, "=")
        length(keyval) != 2 && throw(ArgumentError("Field '$field' did not contain an '='."))
        q[unescape(keyval[1])] = unescape(keyval[2])
    end
    q
end


end # module HttpCommon