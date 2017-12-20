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

export Parser, parse!, parseheaders!, parsebody!, reset!,
       readheaders!, readbody!,
       messagestarted, messagecomplete, headerscomplete, waitingforeof,
       connectionclosed,
       ParsingError, ParsingErrorCode

using ..IOExtras
using ..URIs.parseurlchar

import MbedTLS.SSLContext

import ..@debug, ..@debugshow, ..DEBUG_LEVEL

include("consts.jl")
include("parseutils.jl")


const strict = false # See macro @errifstrict
const enable_passert = false # See macro @passert


"""
    Message

HTTP Message metadata.
- `method::Method`
- `major::Int16`
- `minor::Int16`
- `url::String`
- `status::Int32`
- `upgrade::Bool`
"""

mutable struct Message
    method::Method
    major::Int16
    minor::Int16
    url::String
    status::Int32
    upgrade::Bool
end

Message() =  Message(NOMETHOD, 0, 0, "", 0, false)


"""
    Parser

HTTP Message Parser.

The `Parser` must be configured with output processing callbacks:

- `onheader = f(::Pair{String,String})` is called for each Header Line.

- Body data is passed to `onbodyfragment = f(::SubArray{UInt8,1})`.
  If the Message is chunked or if the Message is passed to `parse!`
  in multiple fragments, then `onbodyfragment` will be called multiple times.

- `onheaderscomplete = f(::Message)` is called at the end of the Header.

Message data can be passed to the `parse!(::Parser, data)` function
or read from a stream by `read!(::IO, ::Parser)`.

e.g.

```
p = Parser()
p.onheaderscomplete = m -> (@show string(m.method); @show m.url)
p.onheader = h -> @show h

parse!(p, \"\"\"
GET /foo HTTP/1.1
Content-Length: 0
Foo: Bar

\"\"\")

h = "Content-Length"=>"0"
h = "Foo"=>"Bar"
string(m.method) = "GET"
m.url = "/foo"
```
"""

mutable struct Parser

    # config
    isheadresponse::Bool # Are we parsing a HEAD Response Message?
    onheader::Function#(::Pair{String,String}
    onbodyfragment::Function#(::SubArray{UInt8,1})
    onheaderscomplete::Function#(::Message)

    # state
    state::UInt8
    header_state::UInt8
    index::UInt8
    flags::UInt8
    content_length::UInt64
    fieldbuffer::IOBuffer
    valuebuffer::IOBuffer

    # output
    message::Message
end


"""
    Parser()

Create an unconfigured `Parser`.
"""

Parser() = Parser(false, x->nothing, x->nothing, x->nothing,
                  s_start_req_or_res, 0, 0, 0, 0,
                  IOBuffer(), IOBuffer(), Message())


"""
    read!(io, ::Parser [, unread=IOExtras.unread!])

Read data from `io` into the `Parser` until `eof`
or until the parser finds the end of the message.

If `readavailable(io)` reads past the end of the Message the excess bytes
are passed to `unread`. This is handled transparently if there is a suitable
`IOExtras.unread!(::IO, SubArray{UInt8, 1})` method defined.

Throws `ParsingError` if input is invalid.
"""

function Base.read!(io::IO, p::Parser; unread=IOExtras.unread!)

    while !eof(io)
        bytes = readavailable(io)
        n = parse!(p, bytes)
        if n < length(bytes)
            unread(io, view(bytes, n+1:length(bytes)))
        end
        if messagecomplete(p)
            return
        end
    end
    @debug 2 "read!(::$(typeof(io)), Parser($(ParsingStateCode(p.state)))) eof!"

    if !messagestarted(p)
        throw(EOFError())
    end
    if !waitingforeof(p)
        throw(ParsingError(p, headerscomplete(p) ? HPE_BODY_INCOMPLETE :
                                                   HPE_HEADERS_INCOMPLETE))
    end
    return
end


"""
    readheaders!(io, ::Parser [, unread=IOExtras.unread!])

Read data from `io` into the `Parser` until `eof`
or until the parser finds the end of the Headers.

If `readavailable(io)` reads past the end of the Headers the excess bytes
are passed to `unread`.

Throws `ParsingError` if input is invalid.
"""

function readheaders!(io::IO, p::Parser; unread=IOExtras.unread!)

    while !eof(io)
        bytes = readavailable(io)
        n = parse!(p, bytes)
        if n < length(bytes)
            unread(io, view(bytes, n+1:length(bytes)))
        end
        if headerscomplete(p)
            return
        end
    end
    @debug 2 "readheaders!(::$(typeof(io)), " *
             "Parser($(ParsingStateCode(p.state)))) eof!"

    if !messagestarted(p)
        throw(EOFError())
    end
    if !waitingforeof(p)
        throw(ParsingError(p, HPE_HEADERS_INCOMPLETE))
    end
    return
end


"""
    readbody!(io, ::Parser [, unread=IOExtras.unread!])

Read data from `io` into the `Parser` until `eof`
or until the parser finds the end of the Message Body.

If `readavailable(io)` reads past the end of the Message the excess bytes
are passed to `unread`.

Throws `ParsingError` if input is invalid.
"""

function readbody!(io::IO, p::Parser; unread=IOExtras.unread!)

    while !eof(io)
        bytes = readavailable(io)
        n = parsebody!(p, bytes)
        if n < length(bytes)
            unread(io, view(bytes, n+1:length(bytes)))
        end
        if messagecomplete(p)
            return
        end
    end
    @debug 2 "readbody!(::$(typeof(io)), " *
             "Parser($(ParsingStateCode(p.state)))) eof!"

    if !waitingforeof(p)
        throw(ParsingError(p, HPE_BODY_INCOMPLETE))
    end
    return
end


"""
    reset!(::Parser)

Revert `Parser` to unconfigured state.
"""

function reset!(p::Parser)

    # config
    p.isheadresponse = false
    p.onheader = x->nothing
    p.onbodyfragment = x->nothing
    p.onheaderscomplete = x->nothing

    # state
    p.state = s_start_req_or_res
    p.header_state = 0
    p.index = 0
    p.flags = 0
    p.content_length = 0
    truncate(p.fieldbuffer, 0)
    truncate(p.valuebuffer, 0)

    # output
    p.message.method = NOMETHOD
    p.message.major = 0
    p.message.minor = 0
    p.message.url = ""
    p.message.status = 0
    p.message.upgrade = false
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
    connectionclosed(::Parser)

Was "Connection: close" parsed?
"""

connectionclosed(p::Parser) = p.flags & F_CONNECTION_CLOSE > 0


isrequest(p::Parser) = p.message.status == 0


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
    enable_passert ? esc(:(@assert $cond)) : :()
end

macro methodstate(meth, i, char)
    return esc(:(Int($meth) << Int(16) | Int($i) << Int(8) | Int($char)))
end


"""
    parse!(::Parser, bytes) -> count

Parse `bytes` and update the `Parser`.

Returns number of bytes consumed.
If `bytes` contains the end of one Message and the start of the next
Message, `parse!` will stop at the end of the first Message.

Throws `ParsingError` if input is invalid.
"""

parse!(p::Parser, bytes::String)::Int = parse!(p, Vector{UInt8}(bytes))

parse!(p::Parser, bytes)::Int = parse!(p, view(bytes, 1:length(bytes)))

const ByteView = typeof(view(UInt8[], 1:0))

function parse!(parser::Parser, bytes::ByteView)::Int

    l = length(bytes)
    c = 0
    while c < l
        if !headerscomplete(parser)
            n = parseheaders!(parser, bytes)
        else
            n = parsebody!(parser, bytes)
        end
        c += n
        if messagecomplete(parser)
            break
        end
        if c < l
            bytes = view(bytes, n+1:length(bytes))
        end
    end
    return c
end


parseheaders!(p::Parser, bytes) = parseheaders!(p, view(bytes, 1:length(bytes)))

function parseheaders!(parser::Parser, bytes::ByteView)::Int

    isempty(bytes) && throw(ArgumentError("bytes must not be empty"))
    headerscomplete(parser) && throw(ArgumentError("headers already complete"))

    len = length(bytes)
    p_state = parser.state
    @debug 2 "parseheaders!(parser.state=$(ParsingStateCode(p_state))), " *
             "$len-bytes:\n" * escapelines(String(collect(bytes))) * ")"

    p = 0
    while p < len && p_state <= s_headers_done

        @debug 3 string("top of while($p < $len) \"",
                        Base.escape_string(string(Char(bytes[p+1]))), "\" ",
                        ParsingStateCode(p_state))
        p += 1
        @inbounds ch = Char(bytes[p])

        if p_state == s_start_req_or_res
            (ch == CR || ch == LF) && continue
            parser.flags = 0
            parser.content_length = ULLONG_MAX

            if ch == 'H'
                p_state = s_res_or_resp_H
            else
                p_state = s_start_req
                p -= 1
            end

        elseif p_state == s_res_or_resp_H
            if ch == 'T'
                p_state = s_res_HT
            else
                @errorif(ch != 'E', HPE_INVALID_CONSTANT)
                parser.message.method = HEAD
                parser.index = 3
                p_state = s_req_method
            end

        elseif p_state == s_start_res
            parser.flags = 0
            parser.content_length = ULLONG_MAX
            if ch == 'H'
                p_state = s_res_H
            elseif ch == CR || ch == LF
            else
                @err HPE_INVALID_CONSTANT
            end

        elseif p_state == s_res_H
            @errorifstrict(ch != 'T')
            p_state = s_res_HT

        elseif p_state == s_res_HT
            @errorifstrict(ch != 'T')
            p_state = s_res_HTT

        elseif p_state == s_res_HTT
            @errorifstrict(ch != 'P')
            p_state = s_res_HTTP

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
            parser.flags = 0
            parser.content_length = ULLONG_MAX
            @errorif(!isalpha(ch), HPE_INVALID_METHOD)

            parser.message.method = Method(0)
            parser.index = 2

            if ch == 'A'
                parser.message.method = ACL
            elseif ch == 'B'
                parser.message.method = BIND
            elseif ch == 'C'
                parser.message.method = CONNECT
            elseif ch == 'D'
                parser.message.method = DELETE
            elseif ch == 'G'
                parser.message.method = GET
            elseif ch == 'H'
                parser.message.method = HEAD
            elseif ch == 'L'
                parser.message.method = LOCK
            elseif ch == 'M'
                parser.message.method = MKCOL
            elseif ch == 'N'
                parser.message.method = NOTIFY
            elseif ch == 'O'
                parser.message.method = OPTIONS
            elseif ch == 'P'
                parser.message.method = POST
            elseif ch == 'R'
                parser.message.method = REPORT
            elseif ch == 'S'
                parser.message.method = SUBSCRIBE
            elseif ch == 'T'
                parser.message.method = TRACE
            elseif ch == 'U'
                parser.message.method = UNLOCK
            else
                @err(HPE_INVALID_METHOD)
            end
            p_state = s_req_method

        elseif p_state == s_req_method
            matcher = string(parser.message.method)
            @debugshow 3 matcher
            @debugshow 3 parser.index
            if ch == ' ' && parser.index == length(matcher) + 1
                p_state = s_req_spaces_before_url
            elseif parser.index > length(matcher)
                @err(HPE_INVALID_METHOD)
            elseif ch == matcher[parser.index]
                @debug 3 "nada"
            elseif isalpha(ch)
                ci = @methodstate(parser.message.method,
                                  Int(parser.index) - 1, ch)
                if ci == @methodstate(POST, 1, 'U')
                    parser.message.method = PUT
                elseif ci == @methodstate(POST, 1, 'A')
                    parser.message.method =  PATCH
                elseif ci == @methodstate(CONNECT, 1, 'H')
                    parser.message.method =  CHECKOUT
                elseif ci == @methodstate(CONNECT, 2, 'P')
                    parser.message.method =  COPY
                elseif ci == @methodstate(MKCOL, 1, 'O')
                    parser.message.method =  MOVE
                elseif ci == @methodstate(MKCOL, 1, 'E')
                    parser.message.method =  MERGE
                elseif ci == @methodstate(MKCOL, 2, 'A')
                    parser.message.method =  MKACTIVITY
                elseif ci == @methodstate(MKCOL, 3, 'A')
                    parser.message.method =  MKCALENDAR
                elseif ci == @methodstate(SUBSCRIBE, 1, 'E')
                    parser.message.method =  SEARCH
                elseif ci == @methodstate(REPORT, 2, 'B')
                    parser.message.method =  REBIND
                elseif ci == @methodstate(POST, 1, 'R')
                    parser.message.method =  PROPFIND
                elseif ci == @methodstate(PROPFIND, 4, 'P')
                    parser.message.method =  PROPPATCH
                elseif ci == @methodstate(PUT, 2, 'R')
                    parser.message.method =  PURGE
                elseif ci == @methodstate(LOCK, 1, 'I')
                    parser.message.method =  LINK
                elseif ci == @methodstate(UNLOCK, 2, 'S')
                    parser.message.method =  UNSUBSCRIBE
                elseif ci == @methodstate(UNLOCK, 2, 'B')
                    parser.message.method =  UNBIND
                elseif ci == @methodstate(UNLOCK, 3, 'I')
                    parser.message.method =  UNLINK
                else
                    @err(HPE_INVALID_METHOD)
                end
            elseif ch == '-' &&
                   parser.index == 2 &&
                   parser.message.method == MKCOL
                @debug 3 "matched MSEARCH"
                parser.message.method = MSEARCH
                parser.index -= 1
            else
                @err(HPE_INVALID_METHOD)
            end
            parser.index += 1
            @debugshow 3 parser.index

        elseif p_state == s_req_spaces_before_url
            ch == ' ' && continue
            if parser.message.method == CONNECT
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
                @debugshow 3 parser.message.url
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
                    parser.header_state = h_C
                elseif c == 'p'
                    parser.header_state = h_matching_proxy_connection
                elseif c == 't'
                    parser.header_state = h_matching_transfer_encoding
                elseif c == 'u'
                    parser.header_state = h_matching_upgrade
                else
                    parser.header_state = h_general
                end

                write(parser.fieldbuffer, bytes[p])
            end

        elseif p_state == s_header_field
            start = p
            while p <= len
                @inbounds ch = Char(bytes[p])
                @debug 3 Base.escape_string(string(ch))
                c = (!strict && ch == ' ') ? ' ' : tokens[Int(ch)+1]
                if c == Char(0)
                    @errorif(ch != ':', HPE_INVALID_HEADER_TOKEN)
                    break
                end
                @debugshow 3 parser.header_state
                h = parser.header_state
                if h == h_general

                elseif h == h_C
                    parser.index += 1
                    parser.header_state = c == 'o' ? h_CO : h_general
                elseif h == h_CO
                    parser.index += 1
                    parser.header_state = c == 'n' ? h_CON : h_general
                elseif h == h_CON
                    parser.index += 1
                    if c == 'n'
                        parser.header_state = h_matching_connection
                    elseif c == 't'
                        parser.header_state = h_matching_content_length
                    else
                        parser.header_state = h_general
                    end
                # connection
                elseif h == h_matching_connection
                    parser.index += 1
                    if parser.index > length(CONNECTION) ||
                       c != CONNECTION[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(CONNECTION)
                        parser.header_state = h_connection
                    end
                # proxy-connection
                elseif h == h_matching_proxy_connection
                    parser.index += 1
                    if parser.index > length(PROXY_CONNECTION) ||
                       c != PROXY_CONNECTION[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(PROXY_CONNECTION)
                        parser.header_state = h_connection
                    end
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
                # upgrade
                elseif h == h_matching_upgrade
                    parser.index += 1
                    if parser.index > length(UPGRADE) ||
                       c != UPGRADE[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(UPGRADE)
                        parser.header_state = h_upgrade
                    end
                elseif @anyeq(h, h_connection, h_content_length,
                              h_transfer_encoding, h_upgrade)
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

            if parser.header_state == h_upgrade
                parser.flags |= F_UPGRADE
                parser.header_state = h_general
            elseif parser.header_state == h_transfer_encoding
                # looking for 'Transfer-Encoding: chunked'
                parser.header_state = ifelse(
                    c == 'c', h_matching_transfer_encoding_chunked, h_general)

            elseif parser.header_state == h_content_length
                @errorif(!isnum(ch), HPE_INVALID_CONTENT_LENGTH)
                @errorif((parser.flags & F_CONTENTLENGTH > 0) != 0,
                         HPE_UNEXPECTED_CONTENT_LENGTH)
                parser.flags |= F_CONTENTLENGTH
                parser.content_length = UInt64(ch - '0')

            elseif parser.header_state == h_connection
                # looking for 'Connection: keep-alive'
                if c == 'k'
                    parser.header_state = h_matching_connection_keep_alive
                # looking for 'Connection: close'
                elseif c == 'c'
                    parser.header_state = h_matching_connection_close
                elseif c == 'u'
                    parser.header_state = h_matching_connection_upgrade
                else
                    parser.header_state = h_matching_connection_token
                end
            # Multi-value `Connection` header
            elseif parser.header_state == h_matching_connection_token_start
            else
              parser.header_state = h_general
            end
            write(parser.valuebuffer, bytes[p])

        elseif p_state == s_header_value
            start = p
            h = parser.header_state
            while p <= len
                @inbounds ch = Char(bytes[p])
                @debug 3 Base.escape_string(string('\'', ch, '\''))
                @debugshow 3 strict
                @debugshow 3 isheaderchar(ch)
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

                @debugshow 3 h
                if h == h_general
                    crlf = findfirst(x->(x == bCR || x == bLF),
                           view(bytes, p:len))
                    p = crlf == 0 ? len : p + crlf - 2

                elseif h == h_connection || h == h_transfer_encoding
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
                        @debugshow 3 Int(parser.content_length)
                        if div(ULLONG_MAX - 10, 10) < t
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

                elseif h == h_matching_connection_token_start
                    # looking for 'Connection: keep-alive'
                    if c == 'k'
                        h = h_matching_connection_keep_alive
                    # looking for 'Connection: close'
                    elseif c == 'c'
                        h = h_matching_connection_close
                    elseif c == 'u'
                        h = h_matching_connection_upgrade
                    elseif tokens[Int(c)+1] > '\0'
                        h = h_matching_connection_token
                    elseif c == ' ' || c == '\t'
                    # Skip lws
                    else
                        h = h_general
                    end
                # looking for 'Connection: keep-alive'
                elseif h == h_matching_connection_keep_alive
                    parser.index += 1
                    if parser.index > length(KEEP_ALIVE) ||
                       c != KEEP_ALIVE[parser.index]
                        h = h_matching_connection_token
                    elseif parser.index == length(KEEP_ALIVE)
                        h = h_connection_keep_alive
                    end

                # looking for 'Connection: close'
                elseif h == h_matching_connection_close
                    parser.index += 1
                    if parser.index > length(CLOSE) ||
                       c != CLOSE[parser.index]
                        h = h_matching_connection_token
                    elseif parser.index == length(CLOSE)
                        h = h_connection_close
                    end

                # looking for 'Connection: upgrade'
                elseif h == h_matching_connection_upgrade
                    parser.index += 1
                    if parser.index > length(UPGRADE) ||
                       c != UPGRADE[parser.index]
                        h = h_matching_connection_token
                    elseif parser.index == length(UPGRADE)
                        h = h_connection_upgrade
                    end

                elseif h == h_matching_connection_token
                    if ch == ','
                        h = h_matching_connection_token_start
                        parser.index = 1
                    end

                elseif h == h_transfer_encoding_chunked
                    if ch != ' '
                        h = h_general
                    end

                elseif @anyeq(h, h_connection_keep_alive, h_connection_close,
                              h_connection_upgrade)
                    if ch == ','
                        if h == h_connection_keep_alive
                            parser.flags |= F_CONNECTION_KEEP_ALIVE
                        elseif h == h_connection_close
                            parser.flags |= F_CONNECTION_CLOSE
                        elseif h == h_connection_upgrade
                            parser.flags |= F_CONNECTION_UPGRADE
                        end
                        h = h_matching_connection_token_start
                        parser.index = 1
                    elseif ch != ' '
                        h = h_matching_connection_token
                    end

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
                parser.onheader(String(take!(parser.fieldbuffer)) =>
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
                if parser.header_state == h_connection_keep_alive
                    parser.flags |= F_CONNECTION_KEEP_ALIVE
                elseif parser.header_state == h_connection_close
                    parser.flags |= F_CONNECTION_CLOSE
                elseif parser.header_state == h_transfer_encoding_chunked
                    parser.flags |= F_CHUNKED
                elseif parser.header_state == h_connection_upgrade
                    parser.flags |= F_CONNECTION_UPGRADE
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
                if parser.header_state == h_connection_keep_alive
                    parser.flags |= F_CONNECTION_KEEP_ALIVE
                elseif parser.header_state == h_connection_close
                    parser.flags |= F_CONNECTION_CLOSE
                elseif parser.header_state == h_connection_upgrade
                    parser.flags |= F_CONNECTION_UPGRADE
                elseif parser.header_state == h_transfer_encoding_chunked
                    parser.flags |= F_CHUNKED
                end

                # header value was empty
                p_state = s_header_field_start
                parser.onheader(String(take!(parser.fieldbuffer)) => "")
                p -= 1
            end

        elseif p_state == s_headers_almost_done
            @errorifstrict(ch != LF)
            p -= 1
            if (parser.flags & F_TRAILING) > 0
                # End of a chunked request
                p_state = s_message_done
            else

                # Cannot use chunked encoding and a content-length header
                # together per the HTTP specification.
                @errorif((parser.flags & F_CHUNKED) > 0 &&
                         (parser.flags & F_CONTENTLENGTH) > 0,
                         HPE_UNEXPECTED_CONTENT_LENGTH)

                p_state = s_headers_done

                # Set this here for onheaderscomplete() callback.
                if (parser.flags & F_UPGRADE > 0) &&
                   (parser.flags & F_CONNECTION_UPGRADE > 0)
                    parser.message.upgrade = isrequest(parser) ||
                                             parser.message.status == 101
                else
                    parser.message.upgrade = isrequest(parser) &&
                                             parser.message.method == CONNECT
                end
                @debugshow 3 parser.message.upgrade
            end

        elseif p_state == s_headers_done
            @errorifstrict(ch != LF)

            @debug 3 "headersdone"
            parser.state = p_state
            parser.onheaderscomplete(parser.message)

            if parser.isheadresponse ||
                   parser.content_length == 0 ||
                   (parser.message.upgrade && isrequest(parser) &&
                    parser.message.method == CONNECT)
                p_state = s_message_done
            elseif parser.flags & F_CHUNKED > 0
                # chunked encoding - ignore Content-Length header
                p_state = s_chunk_size_start
            elseif parser.content_length != ULLONG_MAX
                # Content-Length header given and non-zero
                p_state = s_body_identity
            elseif isrequest(parser) || # FIXME never need eof() for request?
                   div(parser.message.status, 100) == 1 || # 1xx e.g. Continue
                   parser.message.status == 204 ||         # No Content
                   parser.message.status == 304            # Not Modified
                # Assume content-length 0 - read the next
                p_state = s_message_done
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

    @debug 3 "parseheaders!() exiting $(ParsingStateCode(p_state))"

    parser.state = p_state
    return p
end


parsebody!(p::Parser, bytes) = parsebody!(p, view(bytes, 1:length(bytes)))

function parsebody!(parser::Parser, bytes::ByteView)::Int

    isempty(bytes) && throw(ArgumentError("bytes must not be empty"))
    !headerscomplete(parser) && throw(ArgumentError("headers not complete"))

    len = length(bytes)
    p_state = parser.state
    @debug 2 "parsebody!(parser.state=$(ParsingStateCode(p_state))), " *
             "$len-bytes:\n" * escapelines(String(collect(bytes))) * ")"

    p = 0
    while p < len && p_state < s_message_done && p_state != s_trailer_start

        @debug 3 string("top of while($p < $len) \"",
                        Base.escape_string(string(Char(bytes[p+1]))), "\" ",
                        ParsingStateCode(p_state))
        p += 1
        @inbounds ch = Char(bytes[p])

        if p_state == s_body_identity
            to_read = Int(min(parser.content_length, len - p + 1))
            @passert parser.content_length != 0 &&
                     parser.content_length != ULLONG_MAX

            parser.onbodyfragment(view(bytes, p:p + to_read - 1))

            # The difference between advancing content_length and p is because
            # the latter will automaticaly advance on the next loop iteration.
            # Further, if content_length ends up at 0, we want to see the last
            # byte again for our message complete callback.
            parser.content_length -= to_read
            p += to_read - 1

            if parser.content_length == 0
                p_state = s_message_done
            end

        # read until EOF
        elseif p_state == s_body_identity_eof
            parser.onbodyfragment(view(bytes, p:len))
            p = len

        elseif p_state == s_chunk_size_start
            @passert parser.flags & F_CHUNKED > 0

            unhex_val = unhex[Int(ch)+1]
            @errorif(unhex_val == -1, HPE_INVALID_CHUNK_SIZE)

            parser.content_length = unhex_val
            p_state = s_chunk_size

        elseif p_state == s_chunk_size
            @passert parser.flags & F_CHUNKED > 0
            if ch == CR
                p_state = s_chunk_size_almost_done
            else
                unhex_val = unhex[Int(ch)+1]
                @debugshow 3 unhex_val
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
                @debugshow 3 Int(parser.content_length)
                if div(ULLONG_MAX - 16, 16) < t
                    @err(HPE_INVALID_CONTENT_LENGTH)
                end
                parser.content_length = t
            end

        elseif p_state == s_chunk_parameters
            @passert parser.flags & F_CHUNKED > 0
            # just ignore this?. FIXME check for overflow?
            if ch == CR
                p_state = s_chunk_size_almost_done
            end

        elseif p_state == s_chunk_size_almost_done
            @passert parser.flags & F_CHUNKED > 0
            @errorifstrict(ch != LF)

            if parser.content_length == 0
                parser.flags |= F_TRAILING
                p_state = s_trailer_start
            else
                p_state = s_chunk_data
            end

        elseif p_state == s_chunk_data
            to_read = Int(min(parser.content_length, len - p + 1))

            @passert parser.flags & F_CHUNKED > 0
            @passert parser.content_length != 0 &&
                     parser.content_length != ULLONG_MAX

            parser.onbodyfragment(view(bytes, p:p + to_read - 1))

            # See the explanation in s_body_identity for why the content
            # length and data pointers are managed this way.
            parser.content_length -= to_read
            p += Int(to_read) - 1

            if parser.content_length == 0
                p_state = s_chunk_data_almost_done
            end

        elseif p_state == s_chunk_data_almost_done
            @passert parser.flags & F_CHUNKED > 0
            @passert parser.content_length == 0
            @errorifstrict(ch != CR)
            p_state = s_chunk_data_done

        elseif p_state == s_chunk_data_done
            @passert parser.flags & F_CHUNKED > 0
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
            p_state == s_message_done ||
            p_state == s_trailer_start

    @debug 3 "parsebody!() exiting $(ParsingStateCode(p_state))"

    parser.state = p_state
    return p
end


end # module Parsers
