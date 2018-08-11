"""
The parser separates a raw HTTP Message into its component parts.

If the input data is invalid the Parser throws a `HTTP.ParseError`.

The `parse_*` functions processes a single element of a HTTP Message at a time
and return a `SubString` containing the unused portion of the input.

The Parser does not interpret the Message Headers. It is beyond the scope of the
Parser to deal with repeated header fields, multi-line values, cookies or case
normalization.

The Parser has no knowledge of the high-level `Request` and `Response` structs
defined in `Messages.jl`. However, the `Request` and `Response` structs must
have field names compatible with those expected by the `parse_status_line!` and
`parse_request_line!` functions.
"""
module Parsers

export Header, Headers,
       find_end_of_header, find_end_of_line, find_end_of_trailer,
       parse_status_line!, parse_request_line!, parse_header_field,
       parse_chunk_size,
       ParseError

include("parseutils.jl")

const emptyss = SubString("",1,0)
const emptyheader = emptyss => emptyss
const Header = Pair{SubString{String},SubString{String}}
const Headers = Vector{Header}

"""
Parser input was invalid.

Fields:
 - `code`, error code
 - `bytes`, the offending input.
"""
struct ParseError <: Exception
    code::Symbol
    bytes::SubString{String}
end

ParseError(code::Symbol, bytes="") = 
    ParseError(code, first(split(String(bytes), '\n')))

# Regular expressions for parsing HTTP start-line and header-fields

"""
https://tools.ietf.org/html/rfc7230#section-3.1.1
request-line = method SP request-target SP HTTP-version CRLF
"""
const request_line_regex = r"""^
    (?: \r? \n) ?                       #    ignore leading blank line
    ([!#$%&'*+\-.^_`|~[:alnum:]]+) [ ]+ # 1. method = token (RFC7230 3.2.6)
    ([^.][^ \r\n]*) [ ]+                # 2. target
    HTTP/(\d\.\d)                       # 3. version
    \r? \n                              #    CRLF
"""x

"""
https://tools.ietf.org/html/rfc7230#section-3.1.2
status-line = HTTP-version SP status-code SP reason-phrase CRLF

See:
[#190](https://github.com/JuliaWeb/HTTP.jl/issues/190#issuecomment-363314009)
"""
const status_line_regex = r"""^
    [ ]?                                # Issue #190
    HTTP/(\d\.\d) [ ]+                  # 1. version
    (\d\d\d) .*                         # 2. status
    \r? \n                              #    CRLF
"""x

"""
https://tools.ietf.org/html/rfc7230#section-3.2
header-field = field-name ":" OWS field-value OWS
"""
const header_field_regex = r"""^
    ([!#$%&'*+\-.^_`|~[:alnum:]]+) :    # 1. field-name = token (RFC7230 3.2.6)
    [ \t]*                              #    OWS
    ([^\r\n]*?)                         # 2. field-value
    [ \t]*                              #    OWS
    \r? \n                              #    CRLF
    (?= [^ \t])                         #    no WS on next line
"""x

"""
https://tools.ietf.org/html/rfc7230#section-3.2.4
obs-fold = CRLF 1*( SP / HTAB )
"""
const obs_fold_header_field_regex = r"""^
    ([!#$%&'*+\-.^_`|~[:alnum:]]+) :    # 1. field-name = token (RFC7230 3.2.6)
    [ \t]*                              #    OWS
    ([^\r\n]*                           # 2. field-value
        (?: \r? \n [ \t] [^\r\n]*)*)    #    obs-fold
    [ \t]*                              #    OWS
    \r? \n                              #    CRLF
"""x

const empty_header_field_regex = r"^ \r? \n"x

# HTTP start-line and header-field parsing

"""
Arbitrary limit to protect against denial of service attacks.
"""
const header_size_limit = Int(0x10000)

"""
    find_end_of_header(bytes) -> length or 0

Find length of header delimited by `\\r\\n\\r\\n` or `\\n\\n`.
"""
function find_end_of_header(bytes::AbstractVector{UInt8})
    buf = 0xFFFFFFFF
    l = min(length(bytes), header_size_limit)
    i = 1
    while i <= l
        @inbounds x = bytes[i]
        if x == 0x0D || x == 0x0A
            buf = (buf << 8) | UInt32(x)
            if buf == 0x0D0A0D0A || (buf & 0xFFFF) == 0x0A0A
                return i
            end
        else
            buf = 0xFFFFFFFF
        end
        i += 1
    end
    if i > header_size_limit
        throw(ParseError(:HEADER_SIZE_EXCEEDS_LIMIT))
    end

    return 0
end

"""
Parse HTTP request-line `bytes` and set the
`method`, `target` and `version` fields of `request`.
Return a `SubString` containing the header-field lines.
"""
function parse_request_line!(bytes::AbstractString, request)::SubString{String}
    re = request_line_regex
    if !exec(re, bytes)
        throw(ParseError(:INVALID_REQUEST_LINE, bytes))
    end
    request.method = group(1, re, bytes)
    request.target = group(2, re, bytes)
    request.version = VersionNumber(group(3, re, bytes))
    return nextbytes(re, bytes)
end

"""
Parse HTTP response-line `bytes` and set the
`status` and `version` fields of `response`.
Return a `SubString` containing the header-field lines.
"""
function parse_status_line!(bytes::AbstractString, response)::SubString{String}
    re = status_line_regex
    if !exec(re, bytes)
        throw(ParseError(:INVALID_STATUS_LINE, bytes))
    end
    response.version = VersionNumber(group(1, re, bytes))
    response.status = parse(Int, group(2, re, bytes))
    return nextbytes(re, bytes)
end

"""
Parse HTTP header-field.
Return `Pair(field-name => field-value)` and
a `SubString` containing the remaining header-field lines.
"""
function parse_header_field(bytes::SubString{String})::Tuple{Header,SubString{String}}
    # First look for: field-name ":" field-value
    re = header_field_regex
    if exec(re, bytes)
        return (group(1, re, bytes) => group(2, re, bytes)),
                nextbytes(re, bytes)
    end

    # Then check for empty termination line:
    re = empty_header_field_regex
    if exec(re, bytes)
        return emptyheader, nextbytes(re, bytes)
    end

    # Finally look for obsolete line folding format:
    re = obs_fold_header_field_regex
    if exec(re, bytes)
        unfold = SubString(strip(replace(group(2, re, bytes), r"\r?\n"=>"")))
        return (group(1, re, bytes) => unfold), nextbytes(re, bytes)
    end

    throw(ParseError(:INVALID_HEADER_FIELD, bytes))
end

# HTTP Chunked Transfer Coding

"""
Find `\\n` in `bytes`
"""
find_end_of_line(bytes::AbstractVector{UInt8}) =
    (i = findfirst(isequal(UInt8('\n')), bytes)) == nothing ? 0 : i

"""
    find_end_of_trailer(bytes) -> length or 0

Find length of trailer delimited by `\\r\\n\\r\\n` (or starting with `\\r\\n`).
[RFC7230 4.1](https://tools.ietf.org/html/rfc7230#section-4.1)
"""
find_end_of_trailer(bytes::AbstractVector{UInt8}) =
    length(bytes) < 2 ? 0 :
    bytes[2] == UInt8('\n') ? 2 :
    find_end_of_header(bytes)


"""
Arbitrary limit to protect against denial of service attacks.
"""
const chunk_size_limit = typemax(Int32)

"""
Parse HTTP chunk-size.
Return number of bytes of chunk-data.

    chunk-size = 1*HEXDIG
[RFC7230 4.1](https://tools.ietf.org/html/rfc7230#section-4.1)
"""
function parse_chunk_size(bytes::AbstractVector{UInt8})::Int

    chunk_size = Int64(0)
    i = 1
    x = Int64(unhex[bytes[i]])
    while x != -1
        chunk_size = chunk_size * Int64(16) + x
        if chunk_size > chunk_size_limit
            throw(ParseError(:CHUNK_SIZE_EXCEEDS_LIMIT, bytes))
        end
        i += 1
        x = Int64(unhex[bytes[i]])
    end
    if i > 1
        return Int(chunk_size)
    end

    throw(ParseError(:INVALID_CHUNK_SIZE, bytes))
end

const unhex = Int8[
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
    ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
    ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
    , 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,-1,-1,-1,-1,-1,-1
    ,-1,10,11,12,13,14,15,-1,-1,-1,-1,-1,-1,-1,-1,-1
    ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
    ,-1,10,11,12,13,14,15,-1,-1,-1,-1,-1,-1,-1,-1,-1
    ,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
]

function __init__()
    # FIXME Consider turing off `PCRE.UTF` in `Regex.compile_options`
    # https://github.com/JuliaLang/julia/pull/26731#issuecomment-380676770
    Base.compile(status_line_regex)
    Base.compile(request_line_regex)
    Base.compile(header_field_regex)
    Base.compile(empty_header_field_regex)
    Base.compile(obs_fold_header_field_regex)
end

end # module Parsers
