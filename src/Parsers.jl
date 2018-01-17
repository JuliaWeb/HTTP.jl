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
       messagestarted, headerscomplete, bodycomplete, messagecomplete,
       messagehastrailing,
       ParsingError

using ..URIs.parseurlchar

import MbedTLS.SSLContext

import ..@debug, ..@debugshow, ..DEBUG_LEVEL
import ..@require, ..precondition_error
import ..compat_findfirst

include("consts.jl")
include("parseutils.jl")


const strict = false # See macro @errifstrict


const nobytes = view(UInt8[], 1:0)
const ByteView = typeof(nobytes)
const Header = Pair{String,String}
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
    method::String
    major::Int
    minor::Int
    target::String
    status::Int

    Message() = reset!(new())
end

function reset!(m::Message)
    m.method = ""
    m.major = 0
    m.minor = 0
    m.target = ""
    m.status = 0
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
    trailing::Bool
    fieldbuffer::IOBuffer
    valuebuffer::IOBuffer

    # output
    message::Message

    function Parser()
        p = new()
        p.fieldbuffer = IOBuffer()
        p.valuebuffer = IOBuffer()
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
    p.trailing = false
    truncate(p.fieldbuffer, 0)
    truncate(p.valuebuffer, 0)
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
messagehastrailing(p::Parser) = p.trailing


isrequest(p::Parser) = p.message.status == 0


"""
The [`Parser`] input was invalid.

Fields:
 - `code`, internal error code
 - `state`, internal parsing state.
 - `status::Int`, HTTP response status.
 - `msg::String`, error message.
"""

struct ParsingError <: Exception
    code::Symbol
    state::UInt8
    status::Int
    msg::String
end

function ParsingError(p::Parser, code::Symbol)
    ParsingError(code, p.state, p.message.status, "")
end

function Base.show(io::IO, e::ParsingError)
    println(io, string("HTTP.ParsingError: ",
                       get(ERROR_MESSAGES, e.code, "?"), ", ",
                       ParsingStateCode(e.state), ", ",
                       e.status,
                       e.msg == "" ? "" : "\n",
                       e.msg))
end


macro err(code)
    esc(:(parser.state = p_state; throw(ParsingError(parser, $code))))
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

function parse_token(bytes, len, p, buffer; allowed='a')
    start = p
    while p <= len
        @inbounds ch = Char(bytes[p])
        if !istoken(ch) && ch != allowed
            break
        end
        p += 1
    end
    @passert p <= len + 1

    write(buffer, view(bytes, start:p-1))

    if p > len
        return len, false
    else
        return p, true
    end
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

function parseheaders(f, p, bytes)
    v = Vector{UInt8}(bytes)
    parseheaders(f, p, view(v, 1:length(v)))
end

function parseheaders(onheader::Function #=f(::Pair{String,String}) =#,
                      parser::Parser, bytes::ByteView)::ByteView

    @require !isempty(bytes)
    @require messagehastrailing(parser) || !headerscomplete(parser)

    len = length(bytes)
    p_state = parser.state
    @debug 3 "parseheaders(parser.state=$(ParsingStateCode(p_state))), " *
             "$len-bytes:\n" * escapelines(String(collect(bytes))) * ")"

    p = 0
    while p < len && p_state <= s_headers_done

        @debug 4 string("top of while($p < $len) \"",
                        Base.escape_string(string(Char(bytes[p+1]))), "\" ",
                        ParsingStateCode(p_state))
        p += 1
        @inbounds ch = Char(bytes[p])

        if p_state == s_start_req_or_res
            (ch == CR || ch == LF) && continue

            p_state = s_start_req
            p -= 1

        elseif p_state == s_res_first_http_major
            @errorif(!isnum(ch), :HPE_INVALID_VERSION)
            parser.message.major = Int(ch - '0')
            p_state = s_res_http_major

        # major HTTP version or dot
        elseif p_state == s_res_http_major
            if ch == '.'
                p_state = s_res_first_http_minor
                continue
            end
            @errorif(!isnum(ch), :HPE_INVALID_VERSION)
            parser.message.major *= Int(10)
            parser.message.major += Int(ch - '0')
            @errorif(parser.message.major > 999, :HPE_INVALID_VERSION)

        # first digit of minor HTTP version
        elseif p_state == s_res_first_http_minor
            @errorif(!isnum(ch), :HPE_INVALID_VERSION)
            parser.message.minor = Int(ch - '0')
            p_state = s_res_http_minor

        # minor HTTP version or end of request line
        elseif p_state == s_res_http_minor
            if ch == ' '
                p_state = s_res_first_status_code
                continue
            end
            @errorif(!isnum(ch), :HPE_INVALID_VERSION)
            parser.message.minor *= Int(10)
            parser.message.minor += Int(ch - '0')
            @errorif(parser.message.minor > 999, :HPE_INVALID_VERSION)

        elseif p_state == s_res_first_status_code
            if !isnum(ch)
                ch == ' ' && continue
                @err(:HPE_INVALID_STATUS)
            end
            parser.message.status = Int(ch - '0')
            p_state = s_res_status_code

        elseif p_state == s_res_status_code
            if !isnum(ch)
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
                parser.message.status *= Int(10)
                parser.message.status += Int(ch - '0')
                @errorif(parser.message.status > 999, :HPE_INVALID_STATUS)
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
            p -= 1

        elseif p_state == s_req_method

            p, complete = parse_token(bytes, len, p, parser.valuebuffer)

            if complete
                parser.message.method = take!(parser.valuebuffer)
                @inbounds ch = Char(bytes[p])
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
            if parser.message.method == "CONNECT"
                p_state = s_req_server_start
                p -= 1
            elseif ch == '*'
                p_state = s_req_target_wildcard
            else
                p_state = s_req_target_start
                p -= 1
            end

        elseif p_state == s_req_target_wildcard

            if @anyeq(ch, ' ', CR, LF)
                parser.message.target = "*"
                p_state = s_req_http_start
            else
                @err(:HPE_INVALID_TARGET)
            end

        elseif @anyeq(p_state, s_req_target_start,
                               s_req_server_start,
                               s_req_server,
                               s_req_server_with_at,
                               s_req_path,
                               s_req_query_string_start,
                               s_req_query_string,
                               s_req_fragment_start,
                               s_req_fragment,
                               s_req_schema,
                               s_req_schema_slash,
                               s_req_schema_slash_slash)
            start = p
            while p <= len
                @inbounds ch = Char(bytes[p])
                if @anyeq(ch, ' ', CR, LF)
                    @errorif(@anyeq(p_state, s_req_schema, s_req_schema_slash,
                                             s_req_schema_slash_slash,
                                             s_req_server_start),
                             :HPE_INVALID_TARGET)
                    if ch == ' '
                        p_state = s_req_http_start
                    else
                        parser.message.major = Int(0)
                        parser.message.minor = Int(9)
                        p_state = ifelse(ch == CR, s_req_line_almost_done,
                                                   s_header_field_start)
                    end
                    break
                end
                p_state = parseurlchar(p_state, ch, strict)
                @errorif(p_state == s_dead, :HPE_INVALID_TARGET)
                p += 1
            end
            @passert p <= len + 1

            write(parser.valuebuffer, collect(view(bytes, start:p-1)))

            if p_state >= s_req_http_start
                parser.message.target = take!(parser.valuebuffer)
                @debugshow 4 parser.message.target
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
            parser.message.major = Int(ch - '0')
            p_state = s_req_http_major

        # major HTTP version or dot
        elseif p_state == s_req_http_major
            if ch == '.'
                p_state = s_req_first_http_minor
            elseif !isnum(ch)
                @err(:HPE_INVALID_VERSION)
            else
                parser.message.major *= Int(10)
                parser.message.major += Int(ch - '0')
                @errorif(parser.message.major > 999, :HPE_INVALID_VERSION)
            end

        # first digit of minor HTTP version
        elseif p_state == s_req_first_http_minor
            @errorif(!isnum(ch), :HPE_INVALID_VERSION)
            parser.message.minor = Int(ch - '0')
            p_state = s_req_http_minor

        # minor HTTP version or end of request line
        elseif p_state == s_req_http_minor
            if ch == CR
                p_state = s_req_line_almost_done
            elseif ch == LF
                p_state = s_header_field_start
            else
                # FIXME allow spaces after digit?
                @errorif(!isnum(ch), :HPE_INVALID_VERSION)
                parser.message.minor *= Int(10)
                parser.message.minor += Int(ch - '0')
                @errorif(parser.message.minor > 999, :HPE_INVALID_VERSION)
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
                p -= 1
            else
                c = (!strict && ch == ' ') ? ' ' : tokens[Int(ch)+1]
                @errorif(c == Char(0), :HPE_INVALID_HEADER_TOKEN)
                p_state = s_header_field
                p -= 1
            end

        elseif p_state == s_header_field

            p, complete = parse_token(bytes, len, p, parser.fieldbuffer;
                                      allowed = ' ')
            if complete
                @inbounds ch = Char(bytes[p])
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
            p -= 1
        elseif p_state == s_header_value_start
            p_state = s_header_value
            c = lower(ch)

            write(parser.valuebuffer, bytes[p])

        elseif p_state == s_header_value
            start = p
            while p <= len
                @inbounds ch = Char(bytes[p])
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

                c = lower(ch)

                @debugshow 4 h
                crlf = compat_findfirst(x->(x == bCR || x == bLF), view(bytes, p:len))
                p = crlf == 0 ? len : p + crlf - 2

                p += 1
            end
            @passert p <= len + 1

            write(parser.valuebuffer, view(bytes, start:p-1))

            if p_state != s_header_value
                onheader(String(take!(parser.fieldbuffer)) =>
                         String(take!(parser.valuebuffer)))
            end

            p = min(p, len)

        elseif p_state == s_header_almost_done
            @errorif(ch != LF, :HPE_LF_EXPECTED)
            p_state = s_header_value_lws

        elseif p_state == s_header_value_lws
            p -= 1
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
                onheader(String(take!(parser.fieldbuffer)) => "")
                p -= 1
            end

        elseif p_state == s_headers_almost_done
            @errorifstrict(ch != LF)
            p -= 1
            if parser.trailing
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
            ch = Char(bytes[p + 1])
            if ch != CR && ch != LF
                break
            end
            p += 1
        end
    end

    @debug 3 "parseheaders() exiting $(ParsingStateCode(p_state))"

    parser.state = p_state
    return view(bytes, p+1:len)
end


"""
    parsebody(::Parser, bytes) -> data, excess

Parse body data from `bytes`.
Returns decoded `data` and `excess` bytes not parsed.
"""

function parsebody(p, bytes)
    v = Vector{UInt8}(bytes)
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
                parser.trailing = true
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
    "trailing=", p.trailing, ", ",
    "message=", p.message, ")")


end # module Parsers
