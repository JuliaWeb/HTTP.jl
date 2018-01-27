# Based on src/http/ngx_http_parse.c from NGINX copyright Igor Sysoev
#
# Additional changes are licensed under the same terms as NGINX and
# copyright Joyent, Inc. and other Node contributors. All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
#


module Parsers

export Parser, Header, Headers, ByteView, nobytes,
       reset!,
       parseheaders, parsebody,
       parse_status_line, parse_request_line,
       messagestarted, headerscomplete, bodycomplete, messagecomplete,
       messagehastrailing,
       ParsingError

import MbedTLS: SSLContext
using ..IOExtras

import ..@debug, ..@debugshow, ..DEBUG_LEVEL
import ..@require, ..precondition_error
import ..compat_findfirst, ..compat_findprev, ..compat_findnext

include("consts.jl")
include("parseutils.jl")


const strict = false # See macro @errifstrict

const emptyss = SubString("",1,0)
const nobytes = view(UInt8[], 1:0)
const ByteView = typeof(nobytes)
const Header = Pair{SubString{String},SubString{String}}
const Headers = Vector{Header}

"""
 - `method::String`: the HTTP method
   [RFC7230 3.1.1](https://tools.ietf.org/html/rfc7230#section-3.1.1)
 - `major` and `minor`: HTTP version
   [RFC7230 2.6](https://tools.ietf.org/html/rfc7230#section-2.6)
 - `target::String`: request target
   [RFC7230 5.3](https://tools.ietf.org/html/rfc7230#section-5.3)
 - `status::Int`: response status
   [RFC7230 3.1.2](https://tools.ietf.org/html/rfc7230#section-3.1.2)
"""

mutable struct Message
    method::SubString{String}
    version::SubString{String}
    target::SubString{String}
    status::SubString{String}

    Message() = reset!(new())
end

function reset!(m::Message)
    m.method = emptyss
    m.version = emptyss
    m.target = emptyss
    m.status = emptyss
    return m
end


"""
The parser separates a raw HTTP Message into its component parts.

If the input data is invalid the Parser throws a `ParsingError`.

The parser processes a single HTTP Message. If the input stream contains
multiple Messages the Parser stops at the end of the first Message.
The `parseheaders` and `parsebody` functions return a `SubArray` containing the
unuses portion of the input.

The Parser does not interpret the Message Headers except as needed
to parse the Message Body. It is beyond the scope of the Parser to deal
with repeated header fields, multi-line values, cookies or case normalization.

The Parser has no knowledge of the high-level `Request` and `Response` structs
defined in `Messages.jl`. The Parser has it's own low level
[`Message`](@ref) struct that represents both Request and Response
Messages.
"""

mutable struct Parser

    # state
    state::UInt8
    chunk_length::UInt64

    # output
    message::Message

    function Parser()
        p = new()
        p.message = Message()
        return reset!(p)
    end
end


"""
    reset!(::Parser)

Revert `Parser` to unconfigured state.
"""

function reset!(p::Parser)
    p.state = s_start_req_or_res
    p.chunk_length = 0
    reset!(p.message)
    return p
end


"""
    messagestarted(::Parser)

Has the `Parser` begun processng a Message?
"""

messagestarted(p::Parser) = p.state != s_start_req_or_res


"""
    headerscomplete(::Parser)

Has the `Parser` processed the entire Message Header?
"""

headerscomplete(p::Parser) = p.state > s_headers_done


"""
    bodycomplete(::Parser)

Has the `Parser` processed the Message Body?
"""

bodycomplete(p::Parser) = p.state == s_message_done ||
                          p.state == s_trailer_start


"""
    messagecomplete(::Parser)

Has the `Parser` processed the entire Message?
"""

messagecomplete(p::Parser) = p.state >= s_message_done


"""
    messagehastrailing(::Parser)

Is the `Parser` ready to process trailing headers?
"""
messagehastrailing(p::Parser) = p.state == s_trailer_start


isrequest(p::Parser) = isempty(p.message.status)


"""
The [`Parser`] input was invalid.

Fields:
 - `code`, internal error code
 - `state`, internal parsing state.
 - `status`, HTTP response status.
 - `msg::String`, error message.
"""

struct ParsingError <: Exception
    code::Symbol
    state::UInt8
    status::SubString{String}
    msg::String
    bytes::String
    p::Int
end

function ParsingError(parser::Parser, code::Symbol, bytes, p)
    ParsingError(code, parser.state, parser.message.status, "", bytes, p)
end

function Base.show(io::IO, e::ParsingError)
    println(io, string("HTTP.ParsingError: ",
                       get(ERROR_MESSAGES, e.code, "?"), ", ",
                       ParsingStateCode(e.state), ", ",
                       e.status,
                       e.msg == "" ? "" : "\n",
                       e.msg))
    s = String(e.bytes)
    l = compat_findprev(s, '\n', e.p)
    r = compat_findnext(s, '\n', e.p-1)
    error_line = SubString(s, l == 0 ? 1 : l+1, r == 0 ? length(e.bytes) : r)
    println(io, "\"", chomp(error_line), "\"\n",
                lpad("", e.p - l, " "), "^")
end


macro err(code)
    esc(:(parser.state = p_state; throw(ParsingError(parser, $code, String(bytes), p))))
end

macro errorif(cond, err)
    esc(:($cond && @err($err)))
end

macro errorifstrict(cond)
    strict ? esc(:(@errorif($cond, :HPE_STRICT))) : :()
end

macro passert(cond)
    DEBUG_LEVEL > 1 ? esc(:(@assert $cond)) : :()
end

macro methodstate(meth, i, char)
    return esc(:(Int($meth) << Int(16) | Int($i) << Int(8) | Int($char)))
end

function parse_token(bytes, len, p; allowed='a')
    start = p
    while p <= len
        @inbounds ch = bytes[p]
        if !istoken(ch) && ch != allowed
            break
        end
        p = nextind(bytes, p)
    end
    @passert p <= len + 1

    ss = SubString(bytes, start, p-1)

    if p > len
        return ss, len, false
    else
        return ss, p, true
    end
end


rawmatch(re::Regex, str::String, idx::Integer) =
    Base.PCRE.exec(re.regex, str, idx-1, re.match_options, re.match_data)
nextindex(re::Regex) = re.ovec[2]+1
rawgroup(re::Regex, str, i) = SubString(str, re.ovec[2i+1]+1, re.ovec[2i+2])


function __init__()
    Base.compile(status_line)
    Base.compile(request_line)
    Base.compile(header_field)
end


"""
https://tools.ietf.org/html/rfc7230#section-3.1.1
request-line   = method SP request-target SP HTTP-version CRLF
"""

const request_line = r"""^
     \r? \n [ ]*
    ([^ \r\n]+) [ ]+                    # 1. method
    ([^ \r\n]+) [ ]+                    # 2. target
    HTTP/(\d\.\d)                       # 3. version
    \r? \n
"""x


"""
Parse HTTP request-line `bytes` and set the
`method`, `target` and `version` fields of `request`.
Return the index of the first header-field line.
"""

function parse_request_line!(bytes::AbstractString, request)
    re = request_line
    if !rawmatch(re, bytes)
        throw(ParsingError(parser, :INVALID_REQUEST_LINE, bytes, 0))
    end
    request.method = rawgroup(re, bytes, 1)
    request.target = rawgroup(re, bytes, 2)
    request.version = rawgroup(re, bytes, 3)
    return nextindex(re)
end


"""
https://tools.ietf.org/html/rfc7230#section-3.1.2
status-line = HTTP-version SP status-code SP reason-phrase CRLF
"""

const status_line = r"""^
    HTTP/(\d\.\d) [ ]+                  # 1. version
    (\d\d\d) .*                         # 2. status
    \r? \n
"""x


"""
Parse HTTP response-line `bytes` and set the
`status` and `version` fields of `response`.
Return the index of the first header-field line.
"""

function parse_status_line!(bytes::AbstractString, response)
    re = status_line
    if !rawmatch(re, bytes)
        throw(ParsingError(parser, :INVALID_STATUS_LINE, bytes, 0))
    end
    request.version = rawgroup(re, bytes, 1)
    request.status = rawgroup(re, bytes, 2)
    return nextindex(re)
end


"""
https://tools.ietf.org/html/rfc7230#section-3.2
header-field   = field-name ":" OWS field-value OWS
"""

const header_field = r"""^
    [ ]* ([^: \t\r\n]+) [ ]* :
    [ \t]* ([^\r\n]+)
    \r? \n
"""xm


"""
Parse HTTP header-field.
Return `Pair(field-name => field-value)` and
the index of the next header-field line.
"""

function parse_header_field(bytes::AbstractString, i::Int = 1)
    re = header_field 
    if !rawmatch(re, bytes, i)
        throw(ParsingError(parser, :INVALID_HEADER_FIELD, bytes, 0))
    end
    return rawgroup(re, bytes, 1) =>
           rawgroup(re, bytes, 2),
           nextindex(re)
end


#FIXME separate response / request parsing

function re_parseheaders(onheader::Function #=f(::Pair{String,String}) =#,
                         parser::Parser, bytes::String)

    @require !isempty(bytes)
    @require messagehastrailing(parser) || !headerscomplete(parser)

    p_state = parser.state

    p = 1

    if p_state == s_start_req_or_res
        if rawmatch(status_line, bytes, p)
            parser.message.version = rawgroup(status_line, bytes, 1)
            parser.message.status = rawgroup(status_line, bytes, 2)
            p = nextindex(status_line)
        elseif rawmatch(request_line, bytes, p)
            ovec = request_line.ovec
            parser.message.method = rawgroup(request_line, bytes, 1)
            parser.message.target = rawgroup(request_line, bytes, 2)
            parser.message.version = rawgroup(request_line, bytes, 3)
            p = nextindex(request_line)
        else
            throw(ParsingError(parser, :INVALID_START_LINE, bytes, p))
        end
        p_state = s_header_field_start
    end

    while rawmatch(header_field, bytes, p)
        onheader(rawgroup(header_field, bytes, 1) =>
                 rawgroup(header_field, bytes, 2))
        p = nextindex(header_field)
    end
    p_state = s_body_start
    parser.state = p_state
    return
end


"""
    parseheaders(::Parser, bytes) do h::Pair{String,String} ... -> excess

Read headers from `bytes`, passing each field/value pair to `f`.
Returns a `SubArray` containing bytes not parsed.

e.g.
```
excess = parseheaders(p, bytes) do (k,v)
    println("\$k: \$v")
end
```
"""

#parseheaders(f, p, bytes) = parseheaders(f, p, String(bytes))

function parseheaders(onheader::Function #=f(::Pair{String,String}) =#,
                      parser::Parser, bytes::String)

    @require !isempty(bytes)
    @require messagehastrailing(parser) || !headerscomplete(parser)

    field = SubString("")
    len = length(bytes)
    p_state = parser.state
    @debug 3 "parseheaders(parser.state=$(ParsingStateCode(p_state))), " *
             "$len-bytes:\n" * escapelines(String(collect(bytes))) * ")"

    trailing = p_state == s_trailer_start

    p = 0
    while p < len && p_state <= s_headers_done

        @debug 4 string("top of while($p < $len) \"",
                        Base.escape_string(string(bytes[p+1])), "\" ",
                        ParsingStateCode(p_state))
        p = nextind(bytes, p)
        @inbounds ch = bytes[p]

        if p_state == s_start_req_or_res
            (ch == CR || ch == LF) && continue

            p_state = s_start_req
            p = prevind(bytes, p)

        elseif p_state == s_res_first_http_major
            @errorif(!isnum(ch), :HPE_INVALID_VERSION)
            start = p
#            parser.message.major = Int(ch - '0')
            p_state = s_res_http_major

        # major HTTP version or dot
        elseif p_state == s_res_http_major
            if ch == '.'
                p_state = s_res_first_http_minor
                continue
            end
            @errorif(!isnum(ch), :HPE_INVALID_VERSION)
#            parser.message.major *= Int(10)
#            parser.message.major += Int(ch - '0')
            @errorif(parser.message.major > 999, :HPE_INVALID_VERSION)

        # first digit of minor HTTP version
        elseif p_state == s_res_first_http_minor
            @errorif(!isnum(ch), :HPE_INVALID_VERSION)
#            parser.message.minor = Int(ch - '0')
            p_state = s_res_http_minor

        # minor HTTP version or end of request line
        elseif p_state == s_res_http_minor
            if ch == ' '
                parser.message.version = SubString(bytes, start, p-1)
                p_state = s_res_first_status_code
                continue
            end
            @errorif(!isnum(ch), :HPE_INVALID_VERSION)
#            parser.message.minor *= Int(10)
#            parser.message.minor += Int(ch - '0')
#            @errorif(parser.message.minor > 999, :HPE_INVALID_VERSION)

        elseif p_state == s_res_first_status_code
            if !isnum(ch)
                ch == ' ' && continue
                @err(:HPE_INVALID_STATUS)
            end
            start = p
#            parser.message.status = Int(ch - '0')
            p_state = s_res_status_code

        elseif p_state == s_res_status_code
            if !isnum(ch)
                parser.message.status = SubString(bytes, start, p-1)
                if ch == ' '
                    p_state = s_res_status_start
                elseif ch == CR
                    p_state = s_res_line_almost_done
                elseif ch == LF
                    p_state = s_header_field_start
                else
                    @err(:HPE_INVALID_STATUS)
                end
            else
#                parser.message.status *= Int(10)
#                parser.message.status += Int(ch - '0')
#                @errorif(parser.message.status > 999, :HPE_INVALID_STATUS)
            end

        elseif p_state == s_res_status_start
            if ch == CR
                p_state = s_res_line_almost_done
            elseif ch == LF
                p_state = s_header_field_start
            else
                p_state = s_res_status
            end

        elseif p_state == s_res_status
            if ch == CR
                p_state = s_res_line_almost_done
            elseif ch == LF
                p_state = s_header_field_start
            end

        elseif p_state == s_res_line_almost_done
            @errorifstrict(ch != LF)
            p_state = s_header_field_start

        elseif p_state == s_start_req
            (ch == CR || ch == LF) && continue

            @errorif(!istoken(ch), :HPE_INVALID_METHOD)

            p_state = s_req_method
            p = prevind(bytes, p)

        elseif p_state == s_req_method

            parser.message.method, p, complete = parse_token(bytes, len, p)
            @assert complete

            if complete
                @inbounds ch = bytes[p]
                if parser.message.method == "HTTP" && ch == '/'
                    p_state = s_res_first_http_major
                elseif ch == ' '
                    p_state = s_req_spaces_before_target
                else
                    @err(:HPE_INVALID_METHOD)
                end
            end

        elseif p_state == s_req_spaces_before_target
            ch == ' ' && continue
            p_state = s_req_target
            p = prevind(bytes, p)

        elseif (p_state ==  s_req_target)
            start = p
            while p <= len
                @inbounds ch = bytes[p]
                if @anyeq(ch, ' ', CR, LF)
                    if ch == ' '
                        p_state = s_req_http_start
                    else
                        parser.message.version = SubString("0.9")
                        p_state = ifelse(ch == CR, s_req_line_almost_done,
                                                   s_header_field_start)
                    end
                    break
                end
                p = nextind(bytes, p)
            end
            @passert p <= len + 1

            target = SubString(bytes, start, p-1)

            @assert p_state >= s_req_http_start
            if p_state >= s_req_http_start
                @debugshow 4 target
                @errorif(isempty(target) ||
                         target[1] == '.' ||
                         startswith(target, "HTTP/"),
                         :HPE_INVALID_TARGET)
                parser.message.target = target
            end

            p = min(p, len)

        elseif p_state == s_req_http_start
            if ch == 'H'
                p_state = s_req_http_H
            elseif ch == ' '
            else
                @err(:HPE_INVALID_CONSTANT)
            end

        elseif p_state == s_req_http_H
            @errorifstrict(ch != 'T')
            p_state = s_req_http_HT

        elseif p_state == s_req_http_HT
            @errorifstrict(ch != 'T')
            p_state = s_req_http_HTT

        elseif p_state == s_req_http_HTT
            @errorifstrict(ch != 'P')
            p_state = s_req_http_HTTP

        elseif p_state == s_req_http_HTTP
            @errorifstrict(ch != '/')
            p_state = s_req_first_http_major

        # first digit of major HTTP version
        elseif p_state == s_req_first_http_major
            @errorif(ch < '1' || ch > '9', :HPE_INVALID_VERSION)
            start = p
#            parser.message.major = Int(ch - '0')
            p_state = s_req_http_major

        # major HTTP version or dot
        elseif p_state == s_req_http_major
            if ch == '.'
                p_state = s_req_first_http_minor
            elseif !isnum(ch)
                @err(:HPE_INVALID_VERSION)
            else
#                parser.message.major *= Int(10)
#                parser.message.major += Int(ch - '0')
#                @errorif(parser.message.major > 999, :HPE_INVALID_VERSION)
            end

        # first digit of minor HTTP version
        elseif p_state == s_req_first_http_minor
            @errorif(!isnum(ch), :HPE_INVALID_VERSION)
#            parser.message.minor = Int(ch - '0')
            p_state = s_req_http_minor

        # minor HTTP version or end of request line
        elseif p_state == s_req_http_minor
            parser.message.version = SubString(bytes, start, p-1)
            if ch == CR
                p_state = s_req_line_almost_done
            elseif ch == LF
                p_state = s_header_field_start
            else
                # FIXME allow spaces after digit?
                @errorif(!isnum(ch), :HPE_INVALID_VERSION)
#                parser.message.minor *= Int(10)
#                parser.message.minor += Int(ch - '0')
#                @errorif(parser.message.minor > 999, :HPE_INVALID_VERSION)
            end

        # end of request line
        elseif p_state == s_req_line_almost_done
            @errorif(ch != LF, :HPE_LF_EXPECTED)
            p_state = s_header_field_start

        elseif p_state == s_header_field_start ||
               p_state == s_trailer_start
            if ch == CR
                p_state = s_headers_almost_done
            elseif ch == LF
                # they might be just sending \n instead of \r\n so this would be
                # the second \n to denote the end of headers
                p_state = s_headers_almost_done
                p = prevind(bytes, p)
            else
                c = (!strict && ch == ' ') ? ' ' : tokens[Int(ch)+1]
                @errorif(c == Char(0), :HPE_INVALID_HEADER_TOKEN)
                p_state = s_header_field
                p = prevind(bytes, p)
            end

        elseif p_state == s_header_field

            field, p, complete = parse_token(bytes, len, p, allowed = ' ')
            @assert complete
            if complete
                @inbounds ch = bytes[p]
                @errorif(ch != ':', :HPE_INVALID_HEADER_TOKEN)
                p_state = s_header_value_discard_ws
            end

        elseif p_state == s_header_value_discard_ws
            (ch == ' ' || ch == '\t') && continue
            if ch == CR
                p_state = s_header_value_discard_ws_almost_done
                continue
            end
            if ch == LF
                p_state = s_header_value_discard_lws
                continue
            end
            p_state = s_header_value_start
            p = prevind(bytes, p)
        elseif p_state == s_header_value_start
            p_state = s_header_value
            #c = lower(ch)

            p = prevind(bytes, p)

        elseif p_state == s_header_value
            start = p
            while p <= len
                @inbounds ch = bytes[p]
                @debug 4 Base.escape_string(string('\'', ch, '\''))
                if ch == CR
                    p_state = s_header_almost_done
                    break
                elseif ch == LF
                    p_state = s_header_value_lws
                    break
                elseif strict && !isheaderchar(ch)
                    @err(:HPE_INVALID_HEADER_TOKEN)
                end

                #c = lower(ch)

                crlf = compat_findfirst(x->(x == bCR || x == bLF), Vector{UInt8}(SubString(bytes, p, len)))
                p = crlf == 0 ? len : p + crlf - 2

                p = nextind(bytes, p)
            end
            @passert p <= len + 1

            @assert p_state != s_header_value
            if p_state != s_header_value
                onheader(field => SubString(bytes, start, p-1))
                field = SubString("")
            end

            p = min(p, len)

        elseif p_state == s_header_almost_done
            @errorif(ch != LF, :HPE_LF_EXPECTED)
            p_state = s_header_value_lws

        elseif p_state == s_header_value_lws
            p = prevind(bytes, p)
            if ch == ' ' || ch == '\t'
                p_state = s_header_value_start
            else
                # finished the header
                p_state = s_header_field_start
            end

        elseif p_state == s_header_value_discard_ws_almost_done
            @errorifstrict(ch != LF)
            p_state = s_header_value_discard_lws

        elseif p_state == s_header_value_discard_lws
            if ch == ' ' || ch == '\t'
                p_state = s_header_value_discard_ws
            else
                # header value was empty
                p_state = s_header_field_start
                onheader(field => "")
                field = SubString("")
                p = prevind(bytes, p)
            end

        elseif p_state == s_headers_almost_done
            @errorifstrict(ch != LF)
            p = prevind(bytes, p)
            if trailing
                # End of a chunked request
                p_state = s_message_done
            else
                p_state = s_headers_done
            end

        elseif p_state == s_headers_done
            @errorifstrict(ch != LF)

            p_state = s_body_start
        else
            @err :HPE_INVALID_INTERNAL_STATE
        end
    end

    @assert p <= len
    @assert p == len ||
            p_state == s_message_done ||
            p_state == s_body_start


    # Consume trailing end of line after message.
    if p_state == s_message_done
        while p < len
            ch = bytes[p + 1]
            if ch != CR && ch != LF
                break
            end
            p = nextind(bytes, p)
        end
    end

    @debug 3 "parseheaders() exiting $(ParsingStateCode(p_state))"

    parser.state = p_state
    return view(Vector{UInt8}(bytes), p+1:len)
end


"""
    parsebody(::Parser, bytes) -> data, excess

Parse body data from `bytes`.
Returns decoded `data` and `excess` bytes not parsed.
"""

function parsebody(p, bytes)
    v = IOExtras.bytes(bytes)
    parsebody(p, view(v, 1:length(v)))
end

function parsebody(parser::Parser, bytes::ByteView)::Tuple{ByteView,ByteView}

    @require !isempty(bytes)
    @require headerscomplete(parser)

    if parser.state == s_body_start
        parser.state = s_chunk_size_start
    end

    len = length(bytes)
    p_state = parser.state
    @debug 3 "parsebody(parser.state=$(ParsingStateCode(p_state))), " *
             "$len-bytes:\n" * escapelines(String(collect(bytes))) * ")"

    result = nobytes

    p = 0
    while p < len && result == nobytes && p_state != s_trailer_start

        @debug 4 string("top of while($p < $len) \"",
                        Base.escape_string(string(Char(bytes[p+1]))), "\" ",
                        ParsingStateCode(p_state))
        p += 1
        @inbounds ch = Char(bytes[p])

        if p_state == s_chunk_size_start

            unhex_val = unhex[Int(ch)+1]
            @errorif(unhex_val == -1, :HPE_INVALID_CHUNK_SIZE)

            parser.chunk_length = unhex_val
            p_state = s_chunk_size

        elseif p_state == s_chunk_size
            if ch == CR
                p_state = s_chunk_size_almost_done
            else
                unhex_val = unhex[Int(ch)+1]
                if unhex_val == -1
                    if ch == ';' || ch == ' '
                        p_state = s_chunk_parameters
                        continue
                    end
                    @err(:HPE_INVALID_CHUNK_SIZE)
                end
                t = parser.chunk_length
                t *= UInt64(16)
                t += UInt64(unhex_val)

                # Overflow? Test against a conservative limit for simplicity.
                @debugshow 4 Int(parser.chunk_length)
                if div(typemax(UInt64) - 16, 16) < t
                    @err(:HPE_INVALID_CONTENT_LENGTH)
                end
                parser.chunk_length = t
            end

        elseif p_state == s_chunk_parameters
            # just ignore this?. FIXME check for overflow?
            if ch == CR
                p_state = s_chunk_size_almost_done
            end

        elseif p_state == s_chunk_size_almost_done
            @errorifstrict(ch != LF)

            if parser.chunk_length == 0
                p_state = s_trailer_start
            else
                p_state = s_chunk_data
            end

        elseif p_state == s_chunk_data
            to_read = Int(min(parser.chunk_length, len - p + 1))

            @passert parser.chunk_length != 0

            @passert result == nobytes
            result = view(bytes, p:p + to_read - 1)
            parser.chunk_length -= to_read
            p += to_read - 1

            if parser.chunk_length == 0
                p_state = s_chunk_data_almost_done
            end

        elseif p_state == s_chunk_data_almost_done
            @passert parser.chunk_length == 0
            @errorifstrict(ch != CR)
            p_state = s_chunk_data_done

        elseif p_state == s_chunk_data_done
            @errorifstrict(ch != LF)
            p_state = s_chunk_size_start

        else
            @err :HPE_INVALID_INTERNAL_STATE
        end
    end

    @assert p <= len
    @assert p == len ||
            result != nobytes ||
            p_state == s_trailer_start

    # Shortcut: ignore empty trailer.
    if p_state == s_trailer_start
        if p + 1 <= len && bytes[p+1] == bLF
            p += 1
            p_state = s_message_done
        elseif p + 2 <= len && bytes[p+1] == bCR && bytes[p+2] == bLF
            p += 2
            p_state = s_message_done
        end
    end

    @debug 3 "parsebody() exiting $(ParsingStateCode(p_state))"

    parser.state = p_state
    return result, view(bytes, p+1:len)
end


const ERROR_MESSAGES = Dict(
    :HPE_INVALID_VERSION => "invalid HTTP version",
    :HPE_INVALID_STATUS => "invalid HTTP status code",
    :HPE_INVALID_METHOD => "invalid HTTP method",
    :HPE_INVALID_TARGET => "invalid HTTP request target",
    :HPE_LF_EXPECTED => "LF character expected",
    :HPE_INVALID_HEADER_TOKEN => "invalid character in header",
    :HPE_INVALID_CONTENT_LENGTH => "invalid character in content-length header",
    :HPE_INVALID_CHUNK_SIZE => "invalid character in chunk size header",
    :HPE_INVALID_CONSTANT => "invalid constant string",
    :HPE_INVALID_INTERNAL_STATE => "encountered unexpected internal state",
    :HPE_STRICT => "strict mode assertion failed",
)


"""
Tokens as defined by rfc 2616. Also lowercases them.
        token       = 1*<any CHAR except CTLs or separators>
     separators     = "(" | ")" | "<" | ">" | "@"
                    | "," | ";" | ":" | "\" | <">
                    | "/" | "[" | "]" | "?" | "="
                    | "{" | "}" | SP | HT
"""

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


Base.show(io::IO, p::Parser) = print(io, "Parser(",
    "state=", ParsingStateCode(p.state), ", ",
    "message=", p.message, ")")


end # module Parsers
