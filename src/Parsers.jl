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

import ..access_threaded
using ..Strings

export Header, Headers,
       find_end_of_header, find_end_of_chunk_size, find_end_of_trailer,
       parse_status_line!, parse_request_line!, parse_header_field,
       parse_chunk_size,
       ParseError

include("parseutils.jl")

const emptyss = SubString("",1,0)
const emptyheader = emptyss => emptyss
const Header = Pair{SubString{String},SubString{String}}
const Headers = Vector{Header}

"""
    ParseError <: Exception

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

init!(r::RegexAndMatchData) = (Base.compile(r.re); initialize!(r); r)

"""
https://tools.ietf.org/html/rfc7230#section-3.1.1
request-line = method SP request-target SP HTTP-version CRLF
"""
const request_line_regex = RegexAndMatchData[]
function request_line_regex_f()
    r = RegexAndMatchData(r"""^
    (?: \r? \n) ?                       #    ignore leading blank line
    ([!#$%&'*+\-.^_`|~[:alnum:]]+) [ ]+ # 1. method = token (RFC7230 3.2.6)
    ([^.][^ \r\n]*) [ ]+                # 2. target
    HTTP/(\d\.\d)                       # 3. version
    \r? \n                              #    CRLF
    """x)
    init!(r)
end


"""
https://tools.ietf.org/html/rfc7230#section-3.1.2
status-line = HTTP-version SP status-code SP reason-phrase CRLF

See:
[#190](https://github.com/JuliaWeb/HTTP.jl/issues/190#issuecomment-363314009)
"""
const status_line_regex = RegexAndMatchData[]
function status_line_regex_f()
    r = RegexAndMatchData(r"""^
    [ ]?                                # Issue #190
    HTTP/(\d\.\d) [ ]+                  # 1. version
    (\d\d\d) .*                         # 2. status
    \r? \n                              #    CRLF
    """x)
    init!(r)
end

"""
https://tools.ietf.org/html/rfc7230#section-3.2
header-field = field-name ":" OWS field-value OWS
"""
const header_field_regex = RegexAndMatchData[]
function header_field_regex_f()
    r = RegexAndMatchData(r"""^
    ([!#$%&'*+\-.^_`|~[:alnum:]]+) :    # 1. field-name = token (RFC7230 3.2.6)
    [ \t]*                              #    OWS
    ([^\r\n]*?)                         # 2. field-value
    [ \t]*                              #    OWS
    \r? \n                              #    CRLF
    (?= [^ \t])                         #    no WS on next line
    """x)
    init!(r)
end


"""
https://tools.ietf.org/html/rfc7230#section-3.2.4
obs-fold = CRLF 1*( SP / HTAB )
"""
const obs_fold_header_field_regex = RegexAndMatchData[]
function obs_fold_header_field_regex_f()
    r = RegexAndMatchData(r"""^
    ([!#$%&'*+\-.^_`|~[:alnum:]]+) :    # 1. field-name = token (RFC7230 3.2.6)
    [ \t]*                              #    OWS
    ([^\r\n]*                           # 2. field-value
        (?: \r? \n [ \t] [^\r\n]*)*)    #    obs-fold
    [ \t]*                              #    OWS
    \r? \n                              #    CRLF
    """x)
    init!(r)
end

const empty_header_field_regex = RegexAndMatchData[]
function empty_header_field_regex_f()
    r = RegexAndMatchData(r"^ \r? \n"x)
    init!(r)
end


# HTTP start-line and header-field parsing

"""
Arbitrary limit to protect against denial of service attacks.
"""
const header_size_limit = Int(0x10000)

"""
    find_end_of_header(bytes) -> length or 0

Find length of header delimited by `\\r\\n\\r\\n` or `\\n\\n`.
"""
function find_end_of_header(bytes::AbstractVector{UInt8}; allow_obs_fold=true)

    buf = 0xFFFFFFFF
    l = min(length(bytes), header_size_limit)
    i = 1
    while i <= l
        @inbounds x = bytes[i]
        if x == 0x0D || x == 0x0A
            buf = (buf << 8) | UInt32(x)
            # "Although the line terminator for the start-line and header
            #  fields is the sequence CRLF, a recipient MAY recognize a single
            #  LF as a line terminator"
            # [RFC7230 3.5](https://tools.ietf.org/html/rfc7230#section-3.5)
            buf16 = buf & 0xFFFF
            if buf == 0x0D0A0D0A || buf16 == 0x0A0A
                return i
            end
            # "A server that receives an obs-fold ... MUST either reject the
            # message by sending a 400 (Bad Request) ... or replace each
            # received obs-fold with one or more SP octets..."
            # [RFC7230 3.2.4](https://tools.ietf.org/html/rfc7230#section-3.2.4)
            if !allow_obs_fold && (buf16 == 0x0A20 || buf16 == 0x0A09)
                throw(ParseError(:HEADER_CONTAINS_OBS_FOLD, bytes))
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
    re = access_threaded(request_line_regex_f, request_line_regex)
    if !exec(re, bytes)
        throw(ParseError(:INVALID_REQUEST_LINE, bytes))
    end
    request.method = group(1, re, bytes)
    request.target = group(2, re, bytes)
    request.version = HTTPVersion(group(3, re, bytes))
    return nextbytes(re, bytes)
end

"""
Parse HTTP response-line `bytes` and set the
`status` and `version` fields of `response`.
Return a `SubString` containing the header-field lines.
"""
function parse_status_line!(bytes::AbstractString, response)::SubString{String}
    re = access_threaded(status_line_regex_f, status_line_regex)
    if !exec(re, bytes)
        throw(ParseError(:INVALID_STATUS_LINE, bytes))
    end
    response.version = HTTPVersion(group(1, re, bytes))
    response.status = parse(Int, group(2, re, bytes))
    return nextbytes(re, bytes)
end

"""
Parse HTTP header-field.
Return `Pair(field-name => field-value)` and
a `SubString` containing the remaining header-field lines.
"""
function parse_header_field(bytes::SubString{String})::Tuple{Header,SubString{String}}
    # https://github.com/JuliaWeb/HTTP.jl/issues/796
    # there may be certain scenarios where non-ascii characters are
    # included (illegally) in the headers; curl warns on these
    # "malformed headers" and ignores them. we attempt to re-encode
    # these from latin-1 => utf-8 and then try to parse.
    if !isvalid(bytes)
        @warn "malformed HTTP header detected; attempting to re-encode from Latin-1 to UTF8"
        bytes = SubString(iso8859_1_to_utf8(codeunits(bytes)))
    end

    # First look for: field-name ":" field-value
    re = access_threaded(header_field_regex_f, header_field_regex)
    if exec(re, bytes)
        return (group(1, re, bytes) => group(2, re, bytes)),
                nextbytes(re, bytes)
    end

    # Then check for empty termination line:
    re = access_threaded(empty_header_field_regex_f, empty_header_field_regex)
    if exec(re, bytes)
        return emptyheader, nextbytes(re, bytes)
    end

    # Finally look for obsolete line folding format:
    re = access_threaded(obs_fold_header_field_regex_f, obs_fold_header_field_regex)
    if exec(re, bytes)
        unfold = SubString(replace(group(2, re, bytes), r"\r?\n"=>""))
        return (group(1, re, bytes) => unfold), nextbytes(re, bytes)
    end

@label error
    throw(ParseError(:INVALID_HEADER_FIELD, bytes))
end

# HTTP Chunked Transfer Coding

"""
Arbitrary limit to protect against denial of service attacks.
"""
const chunk_size_line_max = 64

const chunk_size_line_min = ncodeunits("0\r\n")

@inline function skip_crlf(bytes, i=1)
    if @inbounds bytes[i] == UInt('\r')
        i += 1
    end
    if @inbounds bytes[i] == UInt('\n')
        i += 1
    end
    return i
end


"""
Find `\\n` after chunk size in `bytes`.
"""
function find_end_of_chunk_size(bytes::AbstractVector{UInt8})
    l = length(bytes)
    if l < chunk_size_line_min
        return 0
    end
    if l > chunk_size_line_max
        l = chunk_size_line_max
    end
    i = skip_crlf(bytes)
    while i <= l
        if @inbounds bytes[i] == UInt('\n')
            return i
        end
        i += 1
    end
    return 0
end

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
    i = skip_crlf(bytes)

    while true
        x = Int64(unhex[@inbounds bytes[i]])
        if x == -1
            break
        end
        chunk_size = chunk_size * Int64(16) + x
        if chunk_size > chunk_size_limit
            throw(ParseError(:CHUNK_SIZE_EXCEEDS_LIMIT, bytes))
        end
        i += 1
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
    nt = @static if isdefined(Base.Threads, :maxthreadid)
        Threads.maxthreadid()
    else
        Threads.nthreads()
    end
    resize!(empty!(status_line_regex),           nt)
    resize!(empty!(request_line_regex),          nt)
    resize!(empty!(header_field_regex),          nt)
    resize!(empty!(obs_fold_header_field_regex), nt)
    resize!(empty!(empty_header_field_regex),    nt)
    return
end

end # module Parsers
