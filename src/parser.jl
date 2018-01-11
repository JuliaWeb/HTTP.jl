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
       waitingforeof, seteof,
       setnobody,
       ParsingError, ParsingErrorCode

using ..URIs.parseurlchar

import MbedTLS.SSLContext

import ..@debug, ..@debugshow, ..DEBUG_LEVEL

include("consts.jl")
include("parseutils.jl")


const strict = false # See macro @errifstrict


const nobytes = view(UInt8[], 1:0)
const ByteView = typeof(nobytes)
const Header = Pair{String,String}
const Headers = Vector{Header}

"""
 - `method::Method`: internal parser `@enum` for HTTP method.
 - `major` and `minor`: HTTP version
 - `url::String`: request URL
 - `status::Int`: response status
"""

mutable struct Message
    method::String
#UNUSED    methodc::Method
    major::Int16
    minor::Int16
    url::String
    status::Int32

    Message() = reset!(new())
end

function reset!(m::Message)
    m.method = ""
#UNUSED    m.methodc = NOMETHOD
    m.major = 0
    m.minor = 0
    m.url = ""
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

    # config
    message_has_no_body::Bool # Are we parsing a HEAD Response Message?

    # state
    state::UInt8
    header_state::UInt8
    index::UInt8
    chunked::Bool
    trailing::Bool
    content_length::UInt64
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
    p.message_has_no_body = false
    p.state = s_start_req_or_res
    reset!(p.message)
    return p
end


"""
    setnobody(::Parser)

Tell the `Parser` not to look for a Message Body.
e.g. for the Response to a HEAD Request.
"""

setnobody(p::Parser) = p.message_has_no_body = true


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
    waitingforeof(::Parser)

Is the `Parser` waiting for the peer to close the connection
to signal the end of the Message Body?
"""
waitingforeof(p::Parser) = p.state == s_body_identity_eof


"""
    seteof(::Parser)

Signal that the peer has closed the connection.
"""
function seteof(p::Parser)
    if p.state == s_body_identity_eof
        p.state = s_message_done
    end
end


"""
    messagehastrailing(::Parser)

Is the `Parser` ready to process trailing headers?
"""
messagehastrailing(p::Parser) = p.trailing


isrequest(p::Parser) = p.message.status == 0


"""
The [`Parser`] input was invalid.

Fields:
 - `code`, internal `@enum ParsingErrorCode`.
 - `state`, internal parsing state.
 - `status::Int32`, HTTP response status.
 - `msg::String`, error message.
"""

struct ParsingError <: Exception
    code::ParsingErrorCode
    state::UInt8
    status::Int32
    msg::String
end

function ParsingError(p::Parser, code::ParsingErrorCode)
    ParsingError(code, p.state, p.message.status, "")
end

function Base.show(io::IO, e::ParsingError)
    println(io, string("HTTP.ParsingError: ",
                       ParsingErrorCodeMap[e.code], ", ",
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
    strict ? esc(:(@errorif($cond, HPE_STRICT))) : :()
end

macro passert(cond)
    DEBUG_LEVEL > 1 ? esc(:(@assert $cond)) : :()
end

macro methodstate(meth, i, char)
    return esc(:(Int($meth) << Int(16) | Int($i) << Int(8) | Int($char)))
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

    isempty(bytes) && throw(ArgumentError("bytes must not be empty"))
    !messagehastrailing(parser) &&
    headerscomplete(parser) && (ArgumentError("headers already complete"))

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

            parser.header_state = h_general
            parser.index = 0
            parser.content_length = unknown_length
            parser.chunked = false
            parser.trailing = false
            truncate(parser.fieldbuffer, 0)
            truncate(parser.valuebuffer, 0)

#UNUSED            if ch == 'H'
#UNUSED                p_state = s_res_or_resp_H
#UNUSED            else
                p_state = s_start_req
                p -= 1
#UNUSED            end

#UNUSED        elseif p_state == s_res_or_resp_H
#UNUSED            if ch == 'T'
#UNUSED                p_state = s_res_HT
#UNUSED            else
#UNUSED                @errorif(ch != 'E', HPE_INVALID_CONSTANT)
#UNUSED                parser.message.methodc = HEAD
#UNUSED                write(parser.valuebuffer, "HE")
#UNUSED                parser.index = 3
#UNUSED                p_state = s_req_method
#UNUSED            end

#UNUSED        elseif p_state == s_start_res
#UNUSED            parser.flags = 0
#UNUSED            parser.content_length = unknown_length
#UNUSED            if ch == 'H'
#UNUSED                p_state = s_res_H
#UNUSED            elseif ch == CR || ch == LF
#UNUSED            else
#UNUSED                @err HPE_INVALID_CONSTANT
#UNUSED            end

#UNUSED        elseif p_state == s_res_H
#UNUSED            @errorifstrict(ch != 'T')
#UNUSED            p_state = s_res_HT

#UNUSED        elseif p_state == s_res_HT
#UNUSED            @errorifstrict(ch != 'T')
#UNUSED            p_state = s_res_HTT

#UNUSED        elseif p_state == s_res_HTT
#UNUSED            @errorifstrict(ch != 'P')
#UNUSED            p_state = s_res_HTTP

        elseif p_state == s_res_HTTP
            @errorifstrict(ch != '/')
            p_state = s_res_first_http_major

        elseif p_state == s_res_first_http_major
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.message.major = Int16(ch - '0')
            p_state = s_res_http_major

        # major HTTP version or dot
        elseif p_state == s_res_http_major
            if ch == '.'
                p_state = s_res_first_http_minor
                continue
            end
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.message.major *= Int16(10)
            parser.message.major += Int16(ch - '0')
            @errorif(parser.message.major > 999, HPE_INVALID_VERSION)

        # first digit of minor HTTP version
        elseif p_state == s_res_first_http_minor
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.message.minor = Int16(ch - '0')
            p_state = s_res_http_minor

        # minor HTTP version or end of request line
        elseif p_state == s_res_http_minor
            if ch == ' '
                p_state = s_res_first_status_code
                continue
            end
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.message.minor *= Int16(10)
            parser.message.minor += Int16(ch - '0')
            @errorif(parser.message.minor > 999, HPE_INVALID_VERSION)

        elseif p_state == s_res_first_status_code
            if !isnum(ch)
                ch == ' ' && continue
                @err(HPE_INVALID_STATUS)
            end
            parser.message.status = Int32(ch - '0')
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
                    @err(HPE_INVALID_STATUS)
                end
            else
                parser.message.status *= Int32(10)
                parser.message.status += Int32(ch - '0')
                @errorif(parser.message.status > 999, HPE_INVALID_STATUS)
            end

        elseif p_state == s_res_status_start
            if ch == CR
                p_state = s_res_line_almost_done
            elseif ch == LF
                p_state = s_header_field_start
            else
                p_state = s_res_status
                parser.index = 1
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
#REDUNDANT            parser.flags = 0
#REDUNDANT            parser.content_length = unknown_length
            @errorif(!isalpha(ch), HPE_INVALID_METHOD)

#= UNUSED
            parser.message.methodc = Method(0)
            parser.index = 2

            if ch == 'A'
                parser.message.methodc = ACL
            elseif ch == 'B'
                parser.message.methodc = BIND
            elseif ch == 'C'
                parser.message.methodc = CONNECT
            elseif ch == 'D'
                parser.message.methodc = DELETE
            elseif ch == 'G'
                parser.message.methodc = GET
            elseif ch == 'H'
                parser.message.methodc = HEAD
            elseif ch == 'L'
                parser.message.methodc = LOCK
            elseif ch == 'M'
                parser.message.methodc = MKCOL
            elseif ch == 'N'
                parser.message.methodc = NOTIFY
            elseif ch == 'O'
                parser.message.methodc = OPTIONS
            elseif ch == 'P'
                parser.message.methodc = POST
            elseif ch == 'R'
                parser.message.methodc = REPORT
            elseif ch == 'S'
                parser.message.methodc = SUBSCRIBE
            elseif ch == 'T'
                parser.message.methodc = TRACE
            elseif ch == 'U'
                parser.message.methodc = UNLOCK
            else
                @err(HPE_INVALID_METHOD)
            end
=#
            p_state = s_req_method

            write(parser.valuebuffer, ch)

        elseif p_state == s_req_method
#UNUSED            matcher = string(parser.message.methodc == xHTTP ? "HTTP" : parser.message.methodc)
#UNUSED            @debugshow 4 matcher
#UNUSED            @debugshow 4 parser.index
            if tokens[Int(ch)+1] == Char(0)
                parser.message.method = take!(parser.valuebuffer)
                if parser.message.method == "HTTP"
                    p_state = s_res_first_http_major
                else
                    p_state = s_req_spaces_before_url
                end
            else
                write(parser.valuebuffer, ch)
            end
#= UNUSED            if ch == '/' && parser.index == length(matcher) + 1 &&
                parser.message.methodc == xHTTP
                p_state = s_res_first_http_major
                truncate(parser.valuebuffer, 0)
            elseif ch == ' ' && parser.index == length(matcher) + 1
                p_state = s_req_spaces_before_url
            elseif parser.index > length(matcher)
                @err(HPE_INVALID_METHOD)
            elseif ch == matcher[parser.index]
                @debug 4 "nada"
            elseif isalpha(ch)
                ci = @methodstate(parser.message.methodc,
                                  Int(parser.index) - 1, ch)
                if ci == @methodstate(POST, 1, 'U')
                    parser.message.methodc = PUT
                elseif ci == @methodstate(HEAD, 1, 'T')
                    parser.message.methodc = xHTTP
                elseif ci == @methodstate(POST, 1, 'A')
                    parser.message.methodc =  PATCH
                elseif ci == @methodstate(CONNECT, 1, 'H')
                    parser.message.methodc =  CHECKOUT
                elseif ci == @methodstate(CONNECT, 2, 'P')
                    parser.message.methodc =  COPY
                elseif ci == @methodstate(MKCOL, 1, 'O')
                    parser.message.methodc =  MOVE
                elseif ci == @methodstate(MKCOL, 1, 'E')
                    parser.message.methodc =  MERGE
                elseif ci == @methodstate(MKCOL, 2, 'A')
                    parser.message.methodc =  MKACTIVITY
                elseif ci == @methodstate(MKCOL, 3, 'A')
                    parser.message.methodc =  MKCALENDAR
                elseif ci == @methodstate(SUBSCRIBE, 1, 'E')
                    parser.message.methodc =  SEARCH
                elseif ci == @methodstate(REPORT, 2, 'B')
                    parser.message.methodc =  REBIND
                elseif ci == @methodstate(POST, 1, 'R')
                    parser.message.methodc =  PROPFIND
                elseif ci == @methodstate(PROPFIND, 4, 'P')
                    parser.message.methodc =  PROPPATCH
                elseif ci == @methodstate(PUT, 2, 'R')
                    parser.message.methodc =  PURGE
                elseif ci == @methodstate(LOCK, 1, 'I')
                    parser.message.methodc =  LINK
                elseif ci == @methodstate(UNLOCK, 2, 'S')
                    parser.message.methodc =  UNSUBSCRIBE
                elseif ci == @methodstate(UNLOCK, 2, 'B')
                    parser.message.methodc =  UNBIND
                elseif ci == @methodstate(UNLOCK, 3, 'I')
                    parser.message.methodc =  UNLINK
                else
                    @err(HPE_INVALID_METHOD)
                end
            elseif ch == '-' &&
                   parser.index == 2 &&
                   parser.message.methodc == MKCOL
                @debug 4 "matched MSEARCH"
                parser.message.methodc = MSEARCH
                parser.index -= 1
            else
                @err(HPE_INVALID_METHOD)
            end
            parser.index += 1
            @debugshow 4 parser.index
=#

        elseif p_state == s_req_spaces_before_url
            ch == ' ' && continue
            if parser.message.method == "CONNECT"
                p_state = s_req_server_start
            else
                p_state = s_req_url_start
            end
            p -= 1

        elseif @anyeq(p_state, s_req_url_start,
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
                             HPE_INVALID_URL)
                    if ch == ' '
                        p_state = s_req_http_start
                    else
                        parser.message.major = Int16(0)
                        parser.message.minor = Int16(9)
                        p_state = ifelse(ch == CR, s_req_line_almost_done,
                                                   s_header_field_start)
                    end
                    break
                end
                p_state = parseurlchar(p_state, ch, strict)
                @errorif(p_state == s_dead, HPE_INVALID_URL)
                p += 1
            end
            @passert p <= len + 1

            write(parser.valuebuffer, view(bytes, start:p-1))

            if p_state >= s_req_http_start
                parser.message.url = take!(parser.valuebuffer)
                @debugshow 4 parser.message.url
            end

            p = min(p, len)

        elseif p_state == s_req_http_start
            if ch == 'H'
                p_state = s_req_http_H
            elseif ch == ' '
            else
                @err(HPE_INVALID_CONSTANT)
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
            @errorif(ch < '1' || ch > '9', HPE_INVALID_VERSION)
            parser.message.major = Int16(ch - '0')
            p_state = s_req_http_major

        # major HTTP version or dot
        elseif p_state == s_req_http_major
            if ch == '.'
                p_state = s_req_first_http_minor
            elseif !isnum(ch)
                @err(HPE_INVALID_VERSION)
            else
                parser.message.major *= Int16(10)
                parser.message.major += Int16(ch - '0')
                @errorif(parser.message.major > 999, HPE_INVALID_VERSION)
            end

        # first digit of minor HTTP version
        elseif p_state == s_req_first_http_minor
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.message.minor = Int16(ch - '0')
            p_state = s_req_http_minor

        # minor HTTP version or end of request line
        elseif p_state == s_req_http_minor
            if ch == CR
                p_state = s_req_line_almost_done
            elseif ch == LF
                p_state = s_header_field_start
            else
                # FIXME allow spaces after digit?
                @errorif(!isnum(ch), HPE_INVALID_VERSION)
                parser.message.minor *= Int16(10)
                parser.message.minor += Int16(ch - '0')
                @errorif(parser.message.minor > 999, HPE_INVALID_VERSION)
            end

        # end of request line
        elseif p_state == s_req_line_almost_done
            @errorif(ch != LF, HPE_LF_EXPECTED)
            p_state = s_header_field_start

        elseif p_state == s_trailer_start ||
               p_state == s_header_field_start
            if ch == CR
                p_state = s_headers_almost_done
            elseif ch == LF
                # they might be just sending \n instead of \r\n so this would be
                # the second \n to denote the end of headers
                p_state = s_headers_almost_done
                p -= 1
            else
                c = (!strict && ch == ' ') ? ' ' : tokens[Int(ch)+1]
                @errorif(c == Char(0), HPE_INVALID_HEADER_TOKEN)
                parser.index = 1
                p_state = s_header_field

                if c == 'c'
                    parser.header_state = h_matching_content_length
#UNUSED                elseif c == 'p'
#UNUSED                    parser.header_state = h_matching_proxy_connection
                elseif c == 't'
                    parser.header_state = h_matching_transfer_encoding
#UNUSED                elseif c == 'u'
#UNUSED                    parser.header_state = h_matching_upgrade
                else
                    parser.header_state = h_general
                end

                write(parser.fieldbuffer, bytes[p])
            end

        elseif p_state == s_header_field
            start = p
            while p <= len
                @inbounds ch = Char(bytes[p])
                @debug 4 Base.escape_string(string(ch))
                c = (!strict && ch == ' ') ? ' ' : tokens[Int(ch)+1]
                if c == Char(0)
                    @errorif(ch != ':', HPE_INVALID_HEADER_TOKEN)
                    break
                end
                @debugshow 4 parser.header_state
                h = parser.header_state
                if h == h_general

#UNUSED                elseif h == h_C
#UNUSED                    parser.index += 1
#UNUSED                    parser.header_state = c == 'o' ? h_CO : h_general
#UNUSED                elseif h == h_CO
#UNUSED                    parser.index += 1
#UNUSED                    parser.header_state = c == 'n' ? h_CON : h_general
#UNUSED                elseif h == h_CON
#UNUSED                    parser.index += 1
#UNUSED                    if c == 'n'
#UNUSED                        parser.header_state = h_matching_connection
#UNUSED                    if c == 't'
#UNUSED                        parser.header_state = h_matching_content_length
#UNUSED                    else
#UNUSED                        parser.header_state = h_general
#UNUSED                    end
#UNUSED                # connection
#UNUSED                elseif h == h_matching_connection
#UNUSED                    parser.index += 1
#UNUSED                    if parser.index > length(CONNECTION) ||
#UNUSED                       c != CONNECTION[parser.index]
#UNUSED                        parser.header_state = h_general
#UNUSED                    elseif parser.index == length(CONNECTION)
#UNUSED                        parser.header_state = h_connection
#UNUSED                    end
#UNUSED                # proxy-connection
#UNUSED                elseif h == h_matching_proxy_connection
#UNUSED                    parser.index += 1
#UNUSED                    if parser.index > length(PROXY_CONNECTION) ||
#UNUSED                       c != PROXY_CONNECTION[parser.index]
#UNUSED                        parser.header_state = h_general
#UNUSED                    elseif parser.index == length(PROXY_CONNECTION)
#UNUSED                        parser.header_state = h_connection
#UNUSED                    end
                # content-length
                elseif h == h_matching_content_length
                    parser.index += 1
                    if parser.index > length(CONTENT_LENGTH) ||
                       c != CONTENT_LENGTH[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(CONTENT_LENGTH)
                        parser.header_state = h_content_length
                    end
                # transfer-encoding
                elseif h == h_matching_transfer_encoding
                    parser.index += 1
                    if parser.index > length(TRANSFER_ENCODING) ||
                       c != TRANSFER_ENCODING[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(TRANSFER_ENCODING)
                        parser.header_state = h_transfer_encoding
                    end
#UNUSED                # upgrade
#UNUSED                elseif h == h_matching_upgrade
#UNUSED                    parser.index += 1
#UNUSED                    if parser.index > length(UPGRADE) ||
#UNUSED                       c != UPGRADE[parser.index]
#UNUSED                        parser.header_state = h_general
#UNUSED                    elseif parser.index == length(UPGRADE)
#UNUSED                        parser.header_state = h_upgrade
#UNUSED                    end
                elseif @anyeq(h, #=h_connection,=# h_content_length,
                              h_transfer_encoding#=, h_upgrade=#)
                    if ch != ' '
                        parser.header_state = h_general
                    end
                else
                    @err HPE_INVALID_INTERNAL_STATE
                end
                p += 1
            end
            @passert p <= len + 1

            if ch == ':'
                p_state = s_header_value_discard_ws
            else
                @passert tokens[Int(ch)+1] != Char(0) || !strict && ch == ' '
            end
            write(parser.fieldbuffer, view(bytes, start:p-1))

            p = min(p, len)

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
            parser.index = 1
            c = lower(ch)

#UNUSED            if parser.header_state == h_upgrade
#UNUSED                parser.flags |= F_UPGRADE
#UNUSED                parser.header_state = h_general
            if parser.header_state == h_transfer_encoding
                # looking for 'Transfer-Encoding: chunked'
                parser.header_state = ifelse(
                    c == 'c', h_matching_transfer_encoding_chunked, h_general)

            elseif parser.header_state == h_content_length
                @errorif(!isnum(ch), HPE_INVALID_CONTENT_LENGTH)
                @errorif(parser.content_length != unknown_length,
                         HPE_UNEXPECTED_CONTENT_LENGTH)
                parser.content_length = UInt64(ch - '0')

#UNUSED            elseif parser.header_state == h_connection
#UNUSED                # looking for 'Connection: keep-alive'
#UNUSED                if c == 'k'
#UNUSED                    parser.header_state = h_matching_connection_keep_alive
#UNUSED                # looking for 'Connection: close'
#UNUSED                elseif c == 'c'
#UNUSED                    parser.header_state = h_matching_connection_close
#UNUSED                if c == 'u'
#UNUSED                    parser.header_state = h_matching_connection_upgrade
#UNUSED                else
#UNUSED                    parser.header_state = h_matching_connection_token
#UNUSED                end
#UNUSED            # Multi-value `Connection` header
#UNUSED            elseif parser.header_state == h_matching_connection_token_start
            else
              parser.header_state = h_general
            end
            write(parser.valuebuffer, bytes[p])

        elseif p_state == s_header_value
            start = p
            h = parser.header_state
            while p <= len
                @inbounds ch = Char(bytes[p])
                @debug 4 Base.escape_string(string('\'', ch, '\''))
                @debugshow 4 strict
                @debugshow 4 isheaderchar(ch)
                if ch == CR
                    p_state = s_header_almost_done
                    break
                elseif ch == LF
                    p_state = s_header_value_lws
                    break
                elseif strict && !isheaderchar(ch)
                    @err(HPE_INVALID_HEADER_TOKEN)
                end

                c = lower(ch)

                @debugshow 4 h
                if h == h_general
                    crlf = findfirst(x->(x == bCR || x == bLF),
                           view(bytes, p:len))
                    p = crlf == 0 ? len : p + crlf - 2

                elseif h == #=h_connection ||=# h == h_transfer_encoding
                    @err HPE_INVALID_INTERNAL_STATE
                elseif h == h_content_length
                    t = UInt64(0)
                    if ch == ' '
                    else
                        if !isnum(ch)
                            parser.header_state = h
                            @err(HPE_INVALID_CONTENT_LENGTH)
                        end
                        t = parser.content_length
                        t *= UInt64(10)
                        t += UInt64(ch - '0')

                        # Overflow?
                        # Test against a conservative limit for simplicity.
                        @debugshow 4 Int(parser.content_length)
                        if div(typemax(UInt64) - 10, 10) < t
                            parser.header_state = h
                            @err(HPE_INVALID_CONTENT_LENGTH)
                        end
                        parser.content_length = t
                     end

                # Transfer-Encoding: chunked
                elseif h == h_matching_transfer_encoding_chunked
                    parser.index += 1
                    if parser.index > length(CHUNKED) ||
                       c != CHUNKED[parser.index]
                        h = h_general
                    elseif parser.index == length(CHUNKED)
                        h = h_transfer_encoding_chunked
                    end

#UNUSED                elseif h == h_matching_connection_token_start
#UNUSED                    # looking for 'Connection: keep-alive'
#UNUSED                    if c == 'k'
#UNUSED                        h = h_matching_connection_keep_alive
#UNUSED                    # looking for 'Connection: close'
#UNUSED                    elseif c == 'c'
#UNUSED                        h = h_matching_connection_close
#UNUSED                    if c == 'u'
#UNUSED                        h = h_matching_connection_upgrade
#UNUSED                    elseif tokens[Int(c)+1] > '\0'
#UNUSED                        h = h_matching_connection_token
#UNUSED                    elseif c == ' ' || c == '\t'
#UNUSED                    # Skip lws
#UNUSED                    else
#UNUSED                        h = h_general
#UNUSED                    end
                # looking for 'Connection: keep-alive'
#UNUSED                elseif h == h_matching_connection_keep_alive
#UNUSED                    parser.index += 1
#UNUSED                    if parser.index > length(KEEP_ALIVE) ||
#UNUSED                       c != KEEP_ALIVE[parser.index]
#UNUSED                        h = h_matching_connection_token
#UNUSED                    elseif parser.index == length(KEEP_ALIVE)
#UNUSED                        h = h_connection_keep_alive
#UNUSED                    end

#UNUSED                # looking for 'Connection: close'
#UNUSED                elseif h == h_matching_connection_close
#UNUSED                    parser.index += 1
#UNUSED                    if parser.index > length(CLOSE) ||
#UNUSED                       c != CLOSE[parser.index]
#UNUSED                        h = h_matching_connection_token
#UNUSED                    elseif parser.index == length(CLOSE)
#UNUSED                        h = h_connection_close
#UNUSED                    end

#UNUSED                # looking for 'Connection: upgrade'
#UNUSED                elseif h == h_matching_connection_upgrade
#UNUSED                    parser.index += 1
#UNUSED                    if parser.index > length(UPGRADE) ||
#UNUSED                       c != UPGRADE[parser.index]
#UNUSED                        h = h_matching_connection_token
#UNUSED                    elseif parser.index == length(UPGRADE)
#UNUSED                        h = h_connection_upgrade
#UNUSED                    end

#UNUSED                elseif h == h_matching_connection_token
#UNUSED                    if ch == ','
#UNUSED                        h = h_matching_connection_token_start
#UNUSED                        parser.index = 1
#UNUSED                    end

                elseif h == h_transfer_encoding_chunked
                    if ch != ' '
                        h = h_general
                    end


#UNUSED                elseif @anyeq(h, h_connection_keep_alive, h_connection_close,
#UNUSED                              h_connection_upgrade)
#UNUSED                    if ch == ','
#UNUSED                        if h == h_connection_keep_alive
#UNUSED                            parser.flags |= F_CONNECTION_KEEP_ALIVE
#UNUSED                        elseif h == h_connection_close
#UNUSED                            parser.flags |= F_CONNECTION_CLOSE
#UNUSED                        elseif h == h_connection_upgrade
#UNUSED                            parser.flags |= F_CONNECTION_UPGRADE
#UNUSED                        end
#UNUSED                        h = h_matching_connection_token_start
#UNUSED                        parser.index = 1
#UNUSED                    elseif ch != ' '
#UNUSED                        h = h_matching_connection_token
#UNUSED                    end

                else
                    p_state = s_header_value
                    h = h_general
                end
                p += 1
            end
            @passert p <= len + 1

            parser.header_state = h

            write(parser.valuebuffer, view(bytes, start:p-1))

            if p_state != s_header_value
                onheader(String(take!(parser.fieldbuffer)) =>
                         String(take!(parser.valuebuffer)))
            end

            p = min(p, len)

        elseif p_state == s_header_almost_done
            @errorif(ch != LF, HPE_LF_EXPECTED)
            p_state = s_header_value_lws

        elseif p_state == s_header_value_lws
            p -= 1
            if ch == ' ' || ch == '\t'
                p_state = s_header_value_start
            else
                # finished the header
#UNUSED                if parser.header_state == h_connection_keep_alive
#UNUSED                    parser.flags |= F_CONNECTION_KEEP_ALIVE
#UNUSED                elseif parser.header_state == h_connection_close
#UNUSED                    parser.flags |= F_CONNECTION_CLOSE
                if parser.header_state == h_transfer_encoding_chunked
                    parser.chunked = true
#UNUSED                elseif parser.header_state == h_connection_upgrade
#UNUSED                    parser.flags |= F_CONNECTION_UPGRADE
                end
                p_state = s_header_field_start
            end

        elseif p_state == s_header_value_discard_ws_almost_done
            @errorifstrict(ch != LF)
            p_state = s_header_value_discard_lws

        elseif p_state == s_header_value_discard_lws
            if ch == ' ' || ch == '\t'
                p_state = s_header_value_discard_ws
            else
#UNUSED                if parser.header_state == h_connection_keep_alive
#UNUSED                    parser.flags |= F_CONNECTION_KEEP_ALIVE
#UNUSED                elseif parser.header_state == h_connection_close
#UNUSED                    parser.flags |= F_CONNECTION_CLOSE
#UNUSED                if parser.header_state == h_connection_upgrade
#UNUSED                    parser.flags |= F_CONNECTION_UPGRADE
                if parser.header_state == h_transfer_encoding_chunked
                    parser.chunked = true
                end

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

                # Cannot use chunked encoding and a content-length header
                # together per the HTTP specification.
                @errorif(parser.chunked &&
                         parser.content_length != unknown_length,
                         HPE_UNEXPECTED_CONTENT_LENGTH)

                p_state = s_headers_done
            end

        elseif p_state == s_headers_done
            @errorifstrict(ch != LF)

            if parser.message_has_no_body ||
               parser.content_length == 0 ||
               parser.message.method == "CONNECT"
                p_state = s_message_done
            elseif parser.chunked
                # chunked encoding - ignore Content-Length header
                p_state = s_chunk_size_start
            elseif parser.content_length != unknown_length
                # Content-Length header given and non-zero
                p_state = s_body_identity
            elseif isrequest(parser) || # RFC 7230, 3.3.3, 6.
                   div(parser.message.status, 100) == 1 || # 1xx e.g. Continue
                   parser.message.status == 204 ||         # No Content
                   parser.message.status == 304            # Not Modified
                p_state = s_message_done                   # =>Content-1ength: 0
            else
                # Read body until EOF
                p_state = s_body_identity_eof
            end

        else
            @err HPE_INVALID_INTERNAL_STATE
        end
    end

    @assert p <= len
    @assert p == len ||
            p_state == s_message_done ||
            p_state == s_chunk_size_start ||
            p_state == s_body_identity ||
            p_state == s_body_identity_eof

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

    isempty(bytes) && throw(ArgumentError("bytes must not be empty"))
    !headerscomplete(parser) && throw(ArgumentError("headers not complete"))

    len = length(bytes)
    p_state = parser.state
    @debug 3 "parsebody(parser.state=$(ParsingStateCode(p_state))), " *
             "$len-bytes:\n" * escapelines(String(collect(bytes))) * ")"

    result = nobytes

    p = 0
    while p < len && result == nobytes && p_state < s_message_done &&
                                          p_state != s_trailer_start

        @debug 4 string("top of while($p < $len) \"",
                        Base.escape_string(string(Char(bytes[p+1]))), "\" ",
                        ParsingStateCode(p_state))
        p += 1
        @inbounds ch = Char(bytes[p])

        if p_state == s_body_identity
            to_read = Int(min(parser.content_length, len - p + 1))
            @passert parser.content_length != 0 &&
                     parser.content_length != unknown_length

            @passert result == nobytes
            result = view(bytes, p:p + to_read - 1)
            parser.content_length -= to_read
            p += to_read - 1

            if parser.content_length == 0
                p_state = s_message_done
            end

        # read until EOF
        elseif p_state == s_body_identity_eof
            @passert result == nobytes
            result = bytes
            p = len

        elseif p_state == s_chunk_size_start
            @passert parser.chunked

            unhex_val = unhex[Int(ch)+1]
            @errorif(unhex_val == -1, HPE_INVALID_CHUNK_SIZE)

            parser.content_length = unhex_val
            p_state = s_chunk_size

        elseif p_state == s_chunk_size
            @passert parser.chunked
            if ch == CR
                p_state = s_chunk_size_almost_done
            else
                unhex_val = unhex[Int(ch)+1]
                @debugshow 4 unhex_val
                if unhex_val == -1
                    if ch == ';' || ch == ' '
                        p_state = s_chunk_parameters
                        continue
                    end
                    @err(HPE_INVALID_CHUNK_SIZE)
                end
                t = parser.content_length
                t *= UInt64(16)
                t += UInt64(unhex_val)

                # Overflow? Test against a conservative limit for simplicity.
                @debugshow 4 Int(parser.content_length)
                if div(typemax(UInt64) - 16, 16) < t
                    @err(HPE_INVALID_CONTENT_LENGTH)
                end
                parser.content_length = t
            end

        elseif p_state == s_chunk_parameters
            @passert parser.chunked
            # just ignore this?. FIXME check for overflow?
            if ch == CR
                p_state = s_chunk_size_almost_done
            end

        elseif p_state == s_chunk_size_almost_done
            @passert parser.chunked
            @errorifstrict(ch != LF)

            if parser.content_length == 0
                parser.trailing = 1
                p_state = s_trailer_start
            else
                p_state = s_chunk_data
            end

        elseif p_state == s_chunk_data
            to_read = Int(min(parser.content_length, len - p + 1))

            @passert parser.chunked
            @passert parser.content_length != 0 &&
                     parser.content_length != unknown_length

            @passert result == nobytes
            result = view(bytes, p:p + to_read - 1)
            parser.content_length -= to_read
            p += to_read - 1

            if parser.content_length == 0
                p_state = s_chunk_data_almost_done
            end

        elseif p_state == s_chunk_data_almost_done
            @passert parser.chunked
            @passert parser.content_length == 0
            @errorifstrict(ch != CR)
            p_state = s_chunk_data_done

        elseif p_state == s_chunk_data_done
            @passert parser.chunked
            @errorifstrict(ch != LF)
            p_state = s_chunk_size_start

        else
            @err HPE_INVALID_INTERNAL_STATE
        end
    end

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

    @assert p <= len
    @assert p == len ||
            result != nobytes ||
            p_state == s_message_done ||
            p_state == s_trailer_start

    @debug 3 "parsebody() exiting $(ParsingStateCode(p_state))"

    parser.state = p_state
    return result, view(bytes, p+1:len)
end


Base.show(io::IO, p::Parser) = print(io, "Parser(",
    "state=", ParsingStateCode(p.state), ", ",
    "chunked=", p.chunked, ", ",
    "trailing=", p.trailing, ", ",
    "content_length=", p.content_length, ", ",
    "message=", p.message, ")")

end # module Parsers
