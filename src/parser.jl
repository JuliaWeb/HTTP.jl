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

const start_state = s_start_req_or_res
const strict = false

mutable struct Parser
    state::UInt8
    header_state::UInt8
    index::UInt8
    flags::UInt8
    nread::UInt32
    content_length::UInt64
    fieldbuffer::Vector{UInt8} #FIXME IOBuffer
    valuebuffer::Vector{UInt8}
    method::HTTP.Method
    major::Int16
    minor::Int16
    url::HTTP.URI
    status::Int32
    headers::Vector{Pair{String,String}}
end

Parser() = Parser(start_state, 0x00, 0, 0, 0, 0, UInt8[], UInt8[], Method(0), 0, 0, HTTP.URI(), 0, Pair{String,String}[])

const DEFAULT_PARSER = Parser()

function reset!(p::Parser)
    p.state = start_state
    p.header_state = 0x00
    p.index = 0x00
    p.flags = 0x00
    p.nread = 0x00000000
    p.content_length = 0x0000000000000000
    empty!(p.fieldbuffer)
    empty!(p.valuebuffer)
    p.method = Method(0)
    p.major = 0
    p.minor = 0
    p.url = HTTP.URI()
    p.status = 0
    empty!(p.headers)
    return
end

# should we just make a copy of the byte vector for URI here?
function onurlbytes(p::Parser, bytes, i, j)
    @debug(PARSING_DEBUG, "onurlbytes")
    append!(p.valuebuffer, view(bytes, i:j))
    return
end

function onurl(p::Parser)
    @debug(PARSING_DEBUG, "onurl")
    @debug(PARSING_DEBUG, String(p.valuebuffer))
    @debug(PARSING_DEBUG, p.method)
    url = copy(p.valuebuffer)
    uri = URIs.http_parser_parse_url(url, 1, length(url), p.method == CONNECT)
    @debug(PARSING_DEBUG, uri)
    p.url = uri
    empty!(p.valuebuffer)
    return
end

function onheaderfieldbytes(p::Parser, bytes, i, j)
    @debug(PARSING_DEBUG, "onheaderfieldbytes")
    append!(p.fieldbuffer, view(bytes, i:j))
    return
end

function onheadervaluebytes(p::Parser, bytes, i, j)
    @debug(PARSING_DEBUG, "onheadervaluebytes")
    append!(p.valuebuffer, view(bytes, i:j))
    return
end

function onheadervalue(p)
    @debug(PARSING_DEBUG, "onheadervalue2")
    key = unsafe_string(pointer(p.fieldbuffer), length(p.fieldbuffer))
    val = unsafe_string(pointer(p.valuebuffer), length(p.valuebuffer))
    push!(p.headers, key => val)
    empty!(p.fieldbuffer)
    empty!(p.valuebuffer)
    return
end

function onbody(r, maintask, bytes, i, j)
    @debug(PARSING_DEBUG, "onbody")
    @debug(PARSING_DEBUG, String(r.body))
    @debug(PARSING_DEBUG, String(bytes[i:j]))
    len = j - i + 1
    #TODO: avoid copying the bytes here? can we somehow write the bytes to a FIFOBuffer more efficiently?
    nb = write(r.body, bytes, i, j)
    if nb < len # didn't write all available bytes
        if current_task() == maintask
            # main request function hasn't returned yet, so not safe to wait
            r.body.max += len - nb
            write(r.body, bytes, i + nb, j)
        else
            while nb < len
                nb += write(r.body, bytes, i + nb, j)
            end
        end
    end
    @debug(PARSING_DEBUG, String(r.body))
    return
end

"""
    HTTP.parse([HTTP.Request, HTTP.Response], str; kwargs...)

Parse a `HTTP.Request` or `HTTP.Response` from a string. `str` must contain at least one
full request or response (but may include more than one). Supported keyword arguments include:

  * `extra`: a `Ref{String}` that will be used to store any extra bytes beyond a full request or response
"""
function parse(T::Type{<:Union{Request, Response}}, str;
                extra::Ref{String}=Ref{String}(),
                maintask::Task=current_task())
    r = T(body=FIFOBuffer())
    reset!(DEFAULT_PARSER)
    err, headerscomplete, messagecomplete, upgrade = parse!(r, DEFAULT_PARSER, Vector{UInt8}(str);
        maintask=maintask)
    if T == Request
        r.uri = DEFAULT_PARSER.url
        r.method = DEFAULT_PARSER.method
    else
        r.status = DEFAULT_PARSER.status
    end
    r.major = DEFAULT_PARSER.major
    r.minor = DEFAULT_PARSER.minor
    err != HPE_OK && throw(ParsingError("error parsing $T: $(ParsingErrorCodeMap[err])"))
    if upgrade != nothing
        extra[] = upgrade
    end
    close(r.body)
    return r
end

function parse!(r::Union{Request, Response}, parser, bytes, len=length(bytes);
        method::Method=GET,
        maintask::Task=current_task())::Tuple{ParsingErrorCode, Bool, Bool, Union{Void,String}}

    err, headerscomplete, messagecomplete, upgrade = parse!(r, parser, bytes, len, method, maintask)

    if headerscomplete && isempty(r.headers)
        for (k, v) in parser.headers
            if k == ""
                r.headers[end] = r.headers[end][1] => string(r.headers[end][2],  v)
#FIXME move this to Headers->Dict conversino function...
            elseif k != "Set-Cookie" && length(r.headers) > 0 && k == r.headers[end].first
                r.headers[end] = r.headers[end][1] => string(r.headers[end][2], ", ", v)
            else
                push!(r.headers, k => v)
            end
        end
    end

    return err, headerscomplete, messagecomplete, upgrade
end

function parse!(r, parser, bytes, len, method, maintask)::Tuple{ParsingErrorCode, Bool, Bool, Union{Void,String}}
    p_state = parser.state
    status_mark = url_mark = header_field_mark = header_field_end_mark = header_value_mark = body_mark = 0
    errno = HPE_OK
    upgrade = headersdone = false
    @debug(PARSING_DEBUG, len)
    @debug(PARSING_DEBUG, ParsingStateCode(p_state))
    if len == 0
        if p_state == s_body_identity_eof
            parser.state = p_state
            @debug(PARSING_DEBUG, "this 6")
            return HPE_OK, true, true, nothing
        elseif @anyeq(p_state, s_dead, s_start_req_or_res, s_start_res, s_start_req)
            return HPE_OK, false, false, nothing
        else
            return HPE_INVALID_EOF_STATE, false, false, nothing
        end
    end

    if p_state == s_header_field
        @debug(PARSING_DEBUG, ParsingStateCode(p_state))
        header_field_mark = header_field_end_mark = 1
    end
    if p_state == s_header_value
        @debug(PARSING_DEBUG, ParsingStateCode(p_state))
        header_value_mark = 1
    end
    if @anyeq(p_state, s_req_path, s_req_schema, s_req_schema_slash, s_req_schema_slash_slash,
                   s_req_server_start, s_req_server, s_req_server_with_at,
                   s_req_query_string_start, s_req_query_string, s_req_fragment,
                   s_req_fragment_start)
        url_mark = 1
    elseif p_state == s_res_status
        status_mark = 1
    end
    p = 1
    old_p = 0
    while p <= len
        @assert p > old_p
        old_p = p
        @inbounds ch = Char(bytes[p])
        @debug(PARSING_DEBUG, "top of main for-loop")
        @debug(PARSING_DEBUG, Base.escape_string(string(ch)))

        if p_state <= s_headers_done
            parser.nread += 1
        end

        @label reexecute

        if p_state == s_dead
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            #= this state is used after a 'Connection: close' message
             # the parser will error out if it reads another message
            =#
            (ch == CR || ch == LF) && @goto breakout
            @err HPE_CLOSED_CONNECTION

        elseif p_state == s_start_req_or_res
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))

            (ch == CR || ch == LF) && @goto breakout
            parser.flags = 0
            parser.content_length = ULLONG_MAX

            if ch == 'H'
                p_state = s_res_or_resp_H
                parser.state = p_state
            else
                p_state = s_start_req
                @goto reexecute
            end

        elseif p_state == s_res_or_resp_H
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            if ch == 'T'
                p_state = s_res_HT
            else
                @errorif(ch != 'E', HPE_INVALID_CONSTANT)
                parser.method = HEAD
                parser.index = 3
                p_state = s_req_method
            end

        elseif p_state == s_start_res
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            parser.flags = 0
            parser.content_length = ULLONG_MAX
            if ch == 'H'
                p_state = s_res_H
            elseif ch == CR || ch == LF
            else
                @err HPE_INVALID_CONSTANT
            end
            parser.state = p_state

        elseif p_state == s_res_H
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != 'T')
            p_state = s_res_HT

        elseif p_state == s_res_HT
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != 'T')
            p_state = s_res_HTT

        elseif p_state == s_res_HTT
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != 'P')
            p_state = s_res_HTTP

        elseif p_state == s_res_HTTP
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != '/')
            p_state = s_res_first_http_major

        elseif p_state == s_res_first_http_major
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.major = Int16(ch - '0')
            p_state = s_res_http_major

        #= major HTTP version or dot =#
        elseif p_state == s_res_http_major
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            if ch == '.'
                p_state = s_res_first_http_minor
                @goto breakout
            end
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.major *= Int16(10)
            parser.major += Int16(ch - '0')
            @errorif(parser.major > 999, HPE_INVALID_VERSION)

        #= first digit of minor HTTP version =#
        elseif p_state == s_res_first_http_minor
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.minor = Int16(ch - '0')
            p_state = s_res_http_minor

        #= minor HTTP version or end of request line =#
        elseif p_state == s_res_http_minor
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            if ch == ' '
                p_state = s_res_first_status_code
                @goto breakout
            end
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.minor *= Int16(10)
            parser.minor += Int16(ch - '0')
            @errorif(parser.minor > 999, HPE_INVALID_VERSION)

        elseif p_state == s_res_first_status_code
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            if !isnum(ch)
                ch == ' ' && @goto breakout
                @err(HPE_INVALID_STATUS)
            end
            parser.status = Int32(ch - '0')
            p_state = s_res_status_code

        elseif p_state == s_res_status_code
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
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
                parser.status *= Int32(10)
                parser.status += Int32(ch - '0')
                @errorif(parser.status > 999, HPE_INVALID_STATUS)
            end

        elseif p_state == s_res_status_start
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            if ch == CR
                p_state = s_res_line_almost_done
            elseif ch == LF
                p_state = s_header_field_start
            else
                status_mark = p
                p_state = s_res_status
                parser.index = 1
            end

        elseif p_state == s_res_status
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            if ch == CR
                p_state = s_res_line_almost_done
                parser.state = p_state
                status_mark = 0
            elseif ch == LF
                p_state = s_header_field_start
                parser.state = p_state
                status_mark = 0
            end

        elseif p_state == s_res_line_almost_done
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != LF)
            p_state = s_header_field_start

        elseif p_state == s_start_req
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            (ch == CR || ch == LF) && @goto breakout
            parser.flags = 0
            parser.content_length = ULLONG_MAX
            @errorif(!isalpha(ch), HPE_INVALID_METHOD)

            parser.method = Method(0)
            parser.index = 2

            if ch == 'A'
                parser.method = ACL
            elseif ch == 'B'
                parser.method = BIND
            elseif ch == 'C'
                parser.method = CONNECT
            elseif ch == 'D'
                parser.method = DELETE
            elseif ch == 'G'
                parser.method = GET
            elseif ch == 'H'
                parser.method = HEAD
            elseif ch == 'L'
                parser.method = LOCK
            elseif ch == 'M'
                parser.method = MKCOL
            elseif ch == 'N'
                parser.method = NOTIFY
            elseif ch == 'O'
                parser.method = OPTIONS
            elseif ch == 'P'
                parser.method = POST
            elseif ch == 'R'
                parser.method = REPORT
            elseif ch == 'S'
                parser.method = SUBSCRIBE
            elseif ch == 'T'
                parser.method = TRACE
            elseif ch == 'U'
                parser.method = UNLOCK
            else
                @err(HPE_INVALID_METHOD)
            end
            p_state = s_req_method
            parser.state = p_state

        elseif p_state == s_req_method
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            matcher = string(parser.method)
            @debug(PARSING_DEBUG, matcher)
            @debug(PARSING_DEBUG, parser.index)
            @debug(PARSING_DEBUG, Base.escape_string(string(ch)))
            if ch == ' ' && parser.index == length(matcher) + 1
                p_state = s_req_spaces_before_url
            elseif parser.index > length(matcher)
                @err(HPE_INVALID_METHOD)
            elseif ch == matcher[parser.index]
                @debug(PARSING_DEBUG, "nada")
            elseif isalpha(ch)
                ci = @shifted(parser.method, Int(parser.index) - 1, ch)
                if ci == @shifted(POST, 1, 'U')
                    parser.method = PUT
                elseif ci == @shifted(POST, 1, 'A')
                    parser.method =  PATCH
                elseif ci == @shifted(CONNECT, 1, 'H')
                    parser.method =  CHECKOUT
                elseif ci == @shifted(CONNECT, 2, 'P')
                    parser.method =  COPY
                elseif ci == @shifted(MKCOL, 1, 'O')
                    parser.method =  MOVE
                elseif ci == @shifted(MKCOL, 1, 'E')
                    parser.method =  MERGE
                elseif ci == @shifted(MKCOL, 2, 'A')
                    parser.method =  MKACTIVITY
                elseif ci == @shifted(MKCOL, 3, 'A')
                    parser.method =  MKCALENDAR
                elseif ci == @shifted(SUBSCRIBE, 1, 'E')
                    parser.method =  SEARCH
                elseif ci == @shifted(REPORT, 2, 'B')
                    parser.method =  REBIND
                elseif ci == @shifted(POST, 1, 'R')
                    parser.method =  PROPFIND
                elseif ci == @shifted(PROPFIND, 4, 'P')
                    parser.method =  PROPPATCH
                elseif ci == @shifted(PUT, 2, 'R')
                    parser.method =  PURGE
                elseif ci == @shifted(LOCK, 1, 'I')
                    parser.method =  LINK
                elseif ci == @shifted(UNLOCK, 2, 'S')
                    parser.method =  UNSUBSCRIBE
                elseif ci == @shifted(UNLOCK, 2, 'B')
                    parser.method =  UNBIND
                elseif ci == @shifted(UNLOCK, 3, 'I')
                    parser.method =  UNLINK
                else
                    @err(HPE_INVALID_METHOD)
                end
            elseif ch == '-' && parser.index == 2 && parser.method == MKCOL
                @debug(PARSING_DEBUG, "matched MSEARCH")
                parser.method = MSEARCH
                parser.index -= 1
            else
                @err(HPE_INVALID_METHOD)
            end
            parser.index += 1
            @debug(PARSING_DEBUG, parser.index)

        elseif p_state == s_req_spaces_before_url
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            ch == ' ' && @goto breakout
            url_mark = p
            if parser.method == CONNECT
                p_state = s_req_server_start
            end
            p_state = URIs.parseurlchar(p_state, ch, strict)
            @errorif(p_state == s_dead, HPE_INVALID_URL)

        elseif @anyeq(p_state, s_req_schema, s_req_schema_slash, s_req_schema_slash_slash, s_req_server_start)
            @errorif(ch in (' ', CR, LF), HPE_INVALID_URL)
            p_state = URIs.parseurlchar(p_state, ch, strict)
            @errorif(p_state == s_dead, HPE_INVALID_URL)

        elseif @anyeq(p_state, s_req_server, s_req_server_with_at, s_req_path, s_req_query_string_start,
                           s_req_query_string, s_req_fragment_start, s_req_fragment)
            if ch == ' '
                p_state = s_req_http_start
                parser.state = p_state
                onurlbytes(parser, bytes, url_mark, p-1)
                onurl(parser)
                url_mark = 0
            elseif ch in (CR, LF)
                parser.major = Int16(0)
                parser.minor = Int16(9)
                p_state = ifelse(ch == CR, s_req_line_almost_done, s_header_field_start)
                parser.state = p_state
                onurlbytes(parser, bytes, url_mark, p-1)
                onurl(parser)
                url_mark = 0
            else
                p_state = URIs.parseurlchar(p_state, ch, strict)
                @errorif(p_state == s_dead, HPE_INVALID_URL)
            end

        elseif p_state == s_req_http_start
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            if ch == 'H'
                p_state = s_req_http_H
            elseif ch == ' '
            else
                @err(HPE_INVALID_CONSTANT)
            end

        elseif p_state == s_req_http_H
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != 'T')
            p_state = s_req_http_HT

        elseif p_state == s_req_http_HT
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != 'T')
            p_state = s_req_http_HTT

        elseif p_state == s_req_http_HTT
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != 'P')
            p_state = s_req_http_HTTP

        elseif p_state == s_req_http_HTTP
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != '/')
            p_state = s_req_first_http_major

        #= first digit of major HTTP version =#
        elseif p_state == s_req_first_http_major
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @errorif(ch < '1' || ch > '9', HPE_INVALID_VERSION)
            parser.major = Int16(ch - '0')
            p_state = s_req_http_major

        #= major HTTP version or dot =#
        elseif p_state == s_req_http_major
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            if ch == '.'
                p_state = s_req_first_http_minor
            elseif !isnum(ch)
                @err(HPE_INVALID_VERSION)
            else
                parser.major *= Int16(10)
                parser.major += Int16(ch - '0')
                @errorif(parser.major > 999, HPE_INVALID_VERSION)
            end

        #= first digit of minor HTTP version =#
        elseif p_state == s_req_first_http_minor
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.minor = Int16(ch - '0')
            p_state = s_req_http_minor

        #= minor HTTP version or end of request line =#
        elseif p_state == s_req_http_minor
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            if ch == CR
                p_state = s_req_line_almost_done
            elseif ch == LF
                p_state = s_header_field_start
            else
                #= XXX allow spaces after digit? =#
                @errorif(!isnum(ch), HPE_INVALID_VERSION)
                parser.minor *= Int16(10)
                parser.minor += Int16(ch - '0')
                @errorif(parser.minor > 999, HPE_INVALID_VERSION)
            end

        #= end of request line =#
        elseif p_state == s_req_line_almost_done
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @errorif(ch != LF, HPE_LF_EXPECTED)
            p_state = s_header_field_start

        elseif p_state == s_header_field_start
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            if ch == CR
                p_state = s_headers_almost_done
            elseif ch == LF
                #= they might be just sending \n instead of \r\n so this would be
                 * the second \n to denote the end of headers=#
                p_state = s_headers_almost_done
                @goto reexecute
            else
                c = (!strict && ch == ' ') ? ' ' : tokens[Int(ch)+1]
                @errorif(c == Char(0), HPE_INVALID_HEADER_TOKEN)
                header_field_mark = header_field_end_mark = p
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
            end

        elseif p_state == s_header_field
            @debug(PARSING_DEBUG, "parsing header_field")
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            start = p
            while p <= len
                ch = Char(bytes[p])
                @debug(PARSING_DEBUG, Base.escape_string(string(ch)))
                c = (!strict && ch == ' ') ? ' ' : tokens[Int(ch)+1]
                if c == Char(0)
                    @errorif(ch != ':', HPE_INVALID_HEADER_TOKEN)
                    break
                end
                h = parser.header_state
                if h == h_general
                    @debug(PARSING_DEBUG, parser.header_state)

                elseif h == h_C
                    @debug(PARSING_DEBUG, parser.header_state)
                    parser.index += 1
                    parser.header_state = c == 'o' ? h_CO : h_general
                elseif h == h_CO
                    @debug(PARSING_DEBUG, parser.header_state)
                    parser.index += 1
                    parser.header_state = c == 'n' ? h_CON : h_general
                elseif h == h_CON
                    @debug(PARSING_DEBUG, parser.header_state)
                    parser.index += 1
                    if c == 'n'
                        parser.header_state = h_matching_connection
                    elseif c == 't'
                        parser.header_state = h_matching_content_length
                    else
                        parser.header_state = h_general
                    end
                #= connection =#
                elseif h == h_matching_connection
                    @debug(PARSING_DEBUG, parser.header_state)
                    parser.index += 1
                    if parser.index > length(CONNECTION) || c != CONNECTION[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(CONNECTION)
                        parser.header_state = h_connection
                    end
                #= proxy-connection =#
                elseif h == h_matching_proxy_connection
                    @debug(PARSING_DEBUG, parser.header_state)
                    parser.index += 1
                    if parser.index > length(PROXY_CONNECTION) || c != PROXY_CONNECTION[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(PROXY_CONNECTION)
                        parser.header_state = h_connection
                    end
                #= content-length =#
                elseif h == h_matching_content_length
                    @debug(PARSING_DEBUG, parser.header_state)
                    parser.index += 1
                    if parser.index > length(CONTENT_LENGTH) || c != CONTENT_LENGTH[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(CONTENT_LENGTH)
                        parser.header_state = h_content_length
                    end
                #= transfer-encoding =#
                elseif h == h_matching_transfer_encoding
                    @debug(PARSING_DEBUG, parser.header_state)
                    parser.index += 1
                    if parser.index > length(TRANSFER_ENCODING) || c != TRANSFER_ENCODING[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(TRANSFER_ENCODING)
                        parser.header_state = h_transfer_encoding
                    end
                #= upgrade =#
                elseif h == h_matching_upgrade
                    @debug(PARSING_DEBUG, parser.header_state)
                    parser.index += 1
                    if parser.index > length(UPGRADE) || c != UPGRADE[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(UPGRADE)
                        parser.header_state = h_upgrade
                    end
                elseif h in (h_connection, h_content_length, h_transfer_encoding, h_upgrade)
                    if ch != ' '
                        parser.header_state = h_general
                    end
                else
                    error("Unknown header_state")
                end
                p += 1
            end

            parser.nread += (p - start)

            if ch == ':'
                p_state = s_header_value_discard_ws
                parser.state = p_state
                header_field_end_mark = p
                if p > header_field_mark
                    onheaderfieldbytes(parser, bytes, header_field_mark, p - 1)
                end
                header_field_mark = 0
            else
                @assert tokens[Int(ch)+1] != Char(0) || !strict && ch == ' '
            end

        elseif p_state == s_header_value_discard_ws
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            (ch == ' ' || ch == '\t') && @goto breakout
            if ch == CR
                p_state = s_header_value_discard_ws_almost_done
                @goto breakout
            end
            if ch == LF
                p_state = s_header_value_discard_lws
                @goto breakout
            end
            @goto s_header_value_start_label
        #= FALLTHROUGH =#
        elseif p_state == s_header_value_start
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @label s_header_value_start_label
            header_value_mark = p
            p_state = s_header_value
            parser.index = 1
            c = lower(ch)

            if parser.header_state == h_upgrade
                parser.flags |= F_UPGRADE
                parser.header_state = h_general
            elseif parser.header_state == h_transfer_encoding
                #= looking for 'Transfer-Encoding: chunked' =#
                parser.header_state =  ifelse(c == 'c', h_matching_transfer_encoding_chunked, h_general)

            elseif parser.header_state == h_content_length
                @errorif(!isnum(ch), HPE_INVALID_CONTENT_LENGTH)
                @errorif((parser.flags & F_CONTENTLENGTH > 0) != 0, HPE_UNEXPECTED_CONTENT_LENGTH)
                parser.flags |= F_CONTENTLENGTH
                parser.content_length = UInt64(ch - '0')

            elseif parser.header_state == h_connection
                #= looking for 'Connection: keep-alive' =#
                if c == 'k'
                    parser.header_state = h_matching_connection_keep_alive
                #= looking for 'Connection: close' =#
                elseif c == 'c'
                    parser.header_state = h_matching_connection_close
                elseif c == 'u'
                    parser.header_state = h_matching_connection_upgrade
                else
                    parser.header_state = h_matching_connection_token
                end
            #= Multi-value `Connection` header =#
            elseif parser.header_state == h_matching_connection_token_start
            else
              parser.header_state = h_general
            end

        elseif p_state == s_header_value
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            start = p
            h = parser.header_state
            while p <= len
                @inbounds ch = Char(bytes[p])
                @debug(PARSING_DEBUG, Base.escape_string(string('\'', ch, '\'')))
                @debug(PARSING_DEBUG, strict)
                @debug(PARSING_DEBUG, isheaderchar(ch))
                if ch == CR
                    p_state = s_header_almost_done
                    parser.header_state = h
                    parser.state = p_state
                    @debug(PARSING_DEBUG, "onheadervalue 1")
                    onheadervaluebytes(parser, bytes, header_value_mark, p - 1)
                    header_value_mark = 0
                    onheadervalue(parser)
                    break
                elseif ch == LF
                    p_state = s_header_almost_done
                    parser.nread += (p - start)
                    parser.header_state = h
                    parser.state = p_state
                    @debug(PARSING_DEBUG, "onheadervalue 2")
                    onheadervaluebytes(parser, bytes, header_value_mark, p - 1)
                    header_value_mark = 0
                    onheadervalue(parser)
                    @goto reexecute
                elseif strict && !isheaderchar(ch)
                    @err(HPE_INVALID_HEADER_TOKEN)
                end

                c = lower(ch)

                if h == h_general
                    @debug(PARSING_DEBUG, parser.header_state)
                    limit = len - p
                    ptr = pointer(bytes, p)
                    @debug(PARSING_DEBUG, Base.escape_string(string('\'', Char(bytes[p]), '\'')))
                    p_cr = ccall(:memchr, Ptr{Void}, (Ptr{Void}, Cint, Csize_t), ptr, CR, limit)
                    p_lf = ccall(:memchr, Ptr{Void}, (Ptr{Void}, Cint, Csize_t), ptr, LF, limit)
                    @debug(PARSING_DEBUG, limit)
                    @debug(PARSING_DEBUG, Int(p_cr))
                    @debug(PARSING_DEBUG, Int(p_lf))
                    if p_cr != C_NULL
                        if p_lf != C_NULL && p_cr >= p_lf
                            @debug(PARSING_DEBUG, Base.escape_string(string('\'', Char(bytes[p + Int(p_lf - ptr + 1)]), '\'')))
                            p += Int(p_lf - ptr)
                        else
                            @debug(PARSING_DEBUG, Base.escape_string(string('\'', Char(bytes[p + Int(p_cr - ptr + 1)]), '\'')))
                            p += Int(p_cr - ptr)
                        end
                    elseif p_lf != C_NULL
                        @debug(PARSING_DEBUG, Base.escape_string(string('\'', Char(bytes[p + Int(p_lf - ptr + 1)]), '\'')))
                        p += Int(p_lf - ptr)
                    else
                        @debug(PARSING_DEBUG, Base.escape_string(string('\'', Char(bytes[len]), '\'')))
                        p = len + 1
                    end
                    p -= 1

                elseif h == h_connection || h == h_transfer_encoding
                    error("Shouldn't get here.")
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

                        #= Overflow? Test against a conservative limit for simplicity. =#
                        @debug(PARSING_DEBUG, "this content_length 1")
                        @debug(PARSING_DEBUG, Int(parser.content_length))
                        if div(ULLONG_MAX - 10, 10) < t
                            parser.header_state = h
                            @err(HPE_INVALID_CONTENT_LENGTH)
                        end
                        parser.content_length = t
                     end

                #= Transfer-Encoding: chunked =#
                elseif h == h_matching_transfer_encoding_chunked
                    parser.index += 1
                    if parser.index > length(CHUNKED) || c != CHUNKED[parser.index]
                        h = h_general
                    elseif parser.index == length(CHUNKED)
                        h = h_transfer_encoding_chunked
                    end

                elseif h == h_matching_connection_token_start
                    #= looking for 'Connection: keep-alive' =#
                    if c == 'k'
                        h = h_matching_connection_keep_alive
                    #= looking for 'Connection: close' =#
                    elseif c == 'c'
                        h = h_matching_connection_close
                    elseif c == 'u'
                        h = h_matching_connection_upgrade
                    elseif tokens[Int(c)+1] > '\0'
                        h = h_matching_connection_token
                    elseif c == ' ' || c == '\t'
                    #= Skip lws =#
                    else
                        h = h_general
                    end
                #= looking for 'Connection: keep-alive' =#
                elseif h == h_matching_connection_keep_alive
                    parser.index += 1
                    if parser.index > length(KEEP_ALIVE) || c != KEEP_ALIVE[parser.index]
                        h = h_matching_connection_token
                    elseif parser.index == length(KEEP_ALIVE)
                        h = h_connection_keep_alive
                    end

                #= looking for 'Connection: close' =#
                elseif h == h_matching_connection_close
                    parser.index += 1
                    if parser.index > length(CLOSE) || c != CLOSE[parser.index]
                        h = h_matching_connection_token
                    elseif parser.index == length(CLOSE)
                        h = h_connection_close
                    end

                #= looking for 'Connection: upgrade' =#
                elseif h == h_matching_connection_upgrade
                    parser.index += 1
                    if parser.index > length(UPGRADE) || c != UPGRADE[parser.index]
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

                elseif h in (h_connection_keep_alive, h_connection_close, h_connection_upgrade)
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
            parser.header_state = h
            parser.nread += (p - start)

        elseif p_state == s_header_almost_done
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @errorif(ch != LF, HPE_LF_EXPECTED)
            p_state = s_header_value_lws

        elseif p_state == s_header_value_lws
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            if ch == ' ' || ch == '\t'
                p_state = s_header_value_start
                @goto reexecute
            end
            #= finished the header =#
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
            @goto reexecute

        elseif p_state == s_header_value_discard_ws_almost_done
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != LF)
            p_state = s_header_value_discard_lws

        elseif p_state == s_header_value_discard_lws
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
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

                #= header value was empty =#
                header_value_mark = p
                p_state = s_header_field_start
                parser.state = p_state
                @debug(PARSING_DEBUG, "onheadervalue 3")
                onheadervaluebytes(parser, bytes, header_value_mark, p - 1)
                header_value_mark = 0
                onheadervalue(parser)
                @goto reexecute
            end

        elseif p_state == s_headers_almost_done
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != LF)
            if (parser.flags & F_TRAILING) > 0
                #= End of a chunked request =#
                p_state = s_message_done
                @goto reexecute
            end

            #= Cannot use chunked encoding and a content-length header together
            per the HTTP specification. =#
            @errorif((parser.flags & F_CHUNKED) > 0 && (parser.flags & F_CONTENTLENGTH) > 0, HPE_UNEXPECTED_CONTENT_LENGTH)

            p_state = s_headers_done

            #= Set this here so that on_headers_complete() callbacks can see it =#
            @debug(PARSING_DEBUG, "checking for upgrade...")
            if (parser.flags & F_UPGRADE > 0) && (parser.flags & F_CONNECTION_UPGRADE > 0)
                upgrade = typeof(r) == Request || parser.status == 101
            else
                upgrade = typeof(r) == Request && parser.method == CONNECT
            end
            @debug(PARSING_DEBUG, upgrade)
            #= Here we call the headers_complete callback. This is somewhat
            * different than other callbacks because if the user returns 1, we
            * will interpret that as saying that this message has no body. This
            * is needed for the annoying case of recieving a response to a HEAD
            * request.
            *
            * We'd like to use CALLBACK_NOTIFY_NOADVANCE() here but we cannot, so
            * we have to simulate it by handling a change in errno below.
            =#
            @debug(PARSING_DEBUG, "headersdone")
            headersdone = true
            if method == HEAD
                parser.flags |= F_SKIPBODY
            elseif method == CONNECT
                upgrade = true
            end
            @goto reexecute

        elseif p_state == s_headers_done
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != LF)

            parser.nread = UInt32(0)

            hasBody = parser.flags & F_CHUNKED > 0 ||
                (parser.content_length > 0 && parser.content_length != ULLONG_MAX)
            if upgrade && ((typeof(r) == Request && parser.method == CONNECT) ||
                                  (parser.flags & F_SKIPBODY) > 0 || !hasBody)
                #= Exit, the rest of the message is in a different protocol. =#
                p_state = ifelse(http_should_keep_alive(parser), start_state, s_dead)
                parser.state = p_state
                @debug(PARSING_DEBUG, "this 1")
                return errno, true, true, String(bytes[p+1:end])
            end

            if parser.flags & F_SKIPBODY > 0
                p_state = ifelse(http_should_keep_alive(parser), start_state, s_dead)
                parser.state = p_state
                @debug(PARSING_DEBUG, "this 2")
                return errno, true, true, nothing
            elseif parser.flags & F_CHUNKED > 0
                #= chunked encoding - ignore Content-Length header =#
                p_state = s_chunk_size_start
            else
                if parser.content_length == 0
                    #= Content-Length header given but zero: Content-Length: 0\r\n =#
                    p_state = ifelse(http_should_keep_alive(parser), start_state, s_dead)
                    parser.state = p_state
                    @debug(PARSING_DEBUG, "this 3")
                    return errno, true, true, nothing
                elseif parser.content_length != ULLONG_MAX
                    #= Content-Length header given and non-zero =#
                    p_state = s_body_identity
                    @debug(PARSING_DEBUG, ParsingStateCode(p_state))
                else
                    if !http_message_needs_eof(parser)
                        #= Assume content-length 0 - read the next =#
                        p_state = ifelse(http_should_keep_alive(parser), start_state, s_dead)
                        parser.state = p_state
                        @debug(PARSING_DEBUG, "this 4")
                        #return errno, true, true, String(bytes[p+1:end])
                        return errno, true, true, p >= len ? nothing : String(bytes[p:end])
                    else
                        #= Read body until EOF =#
                        p_state = s_body_identity_eof
                        @debug(PARSING_DEBUG, ParsingStateCode(p_state))
                    end
                end
            end

        elseif p_state == s_body_identity
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            to_read = UInt64(min(parser.content_length, len - p + 1))
            assert(parser.content_length != 0 && parser.content_length != ULLONG_MAX)

            #= The difference between advancing content_length and p is because
            * the latter will automaticaly advance on the next loop iteration.
            * Further, if content_length ends up at 0, we want to see the last
            * byte again for our message complete callback.
            =#
            body_mark = p
            parser.content_length -= to_read
            p += Int(to_read) - 1

            if parser.content_length == 0
                p_state = s_message_done

                #= Mimic CALLBACK_DATA_NOADVANCE() but with one extra byte.
                *
                * The alternative to doing this is to wait for the next byte to
                * trigger the data callback, just as in every other case. The
                * problem with this is that this makes it difficult for the test
                * harness to distinguish between complete-on-EOF and
                * complete-on-length. It's not clear that this distinction is
                * important for applications, but let's keep it for now.
                =#
                @debug(PARSING_DEBUG, "this onbody 1")
                onbody(r, maintask, bytes, body_mark, p)
                body_mark = 0
                @goto reexecute
            end

        #= read until EOF =#
        elseif p_state == s_body_identity_eof
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            body_mark = p
            p = len

        elseif p_state == s_message_done
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            # p_state = ifelse(http_should_keep_alive(parser, r), start_state, s_dead)
            parser.state = p_state
            @debug(PARSING_DEBUG, "this 5")
            if upgrade
                #= Exit, the rest of the message is in a different protocol. =#
                parser.state = p_state
                return errno, true, true, String(bytes[p+1:end])
            end

        elseif p_state == s_chunk_size_start
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            assert(parser.nread == 1)
            assert(parser.flags & F_CHUNKED > 0)

            unhex_val = unhex[Int(ch)+1]
            @errorif(unhex_val == -1, HPE_INVALID_CHUNK_SIZE)

            parser.content_length = unhex_val
            p_state = s_chunk_size

        elseif p_state == s_chunk_size
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            assert(parser.flags & F_CHUNKED > 0)
            if ch == CR
                p_state = s_chunk_size_almost_done
            else
                unhex_val = unhex[Int(ch)+1]
                @debug(PARSING_DEBUG, unhex_val)
                if unhex_val == -1
                    if ch == ';' || ch == ' '
                        p_state = s_chunk_parameters
                        @goto breakout
                    end
                    @err(HPE_INVALID_CHUNK_SIZE)
                end
                t = parser.content_length
                t *= UInt64(16)
                t += UInt64(unhex_val)

                #= Overflow? Test against a conservative limit for simplicity. =#
                @debug(PARSING_DEBUG, "this content_length 2")
                @debug(PARSING_DEBUG, Int(parser.content_length))
                if div(ULLONG_MAX - 16, 16) < t
                    @err(HPE_INVALID_CONTENT_LENGTH)
                end
                parser.content_length = t
            end

        elseif p_state == s_chunk_parameters
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            assert(parser.flags & F_CHUNKED > 0)
            #= just ignore this shit. TODO check for overflow =#
            if ch == CR
                p_state = s_chunk_size_almost_done
            end

        elseif p_state == s_chunk_size_almost_done
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            assert(parser.flags & F_CHUNKED > 0)
            @strictcheck(ch != LF)

            parser.nread = 0

            if parser.content_length == 0
                parser.flags |= F_TRAILING
                p_state = s_header_field_start
            else
                p_state = s_chunk_data
            end

        elseif p_state == s_chunk_data
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            to_read = UInt64(min(parser.content_length, len - p + 1))

            assert(parser.flags & F_CHUNKED > 0)
            assert(parser.content_length != 0 && parser.content_length != ULLONG_MAX)

            #= See the explanation in s_body_identity for why the content
            * length and data pointers are managed this way.
            =#
            body_mark = p
            parser.content_length -= to_read
            p += Int(to_read) - 1

            if parser.content_length == 0
                p_state = s_chunk_data_almost_done
            end

        elseif p_state == s_chunk_data_almost_done
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            assert(parser.flags & F_CHUNKED > 0)
            assert(parser.content_length == 0)
            @strictcheck(ch != CR)
            p_state = s_chunk_data_done
            @debug(PARSING_DEBUG, "this onbody 2")
            body_mark > 0 && onbody(r, maintask, bytes, body_mark, p - 1)
            body_mark = 0

        elseif p_state == s_chunk_data_done
            @debug(PARSING_DEBUG, ParsingStateCode(p_state))
            assert(parser.flags & F_CHUNKED > 0)
            @strictcheck(ch != LF)
            parser.nread = 0
            p_state = s_chunk_size_start

        else
            error("unhandled state")
        end
        @label breakout
        p += 1
    end

    #= Run callbacks for any marks that we have leftover after we ran our of
     * bytes. There should be at most one of these set, so it's OK to invoke
     * them in series (unset marks will not result in callbacks).
     *
     * We use the NOADVANCE() variety of callbacks here because 'p' has already
     * overflowed 'data' and this allows us to correct for the off-by-one that
     * we'd otherwise have (since CALLBACK_DATA() is meant to be run with a 'p'
     * value that's in-bounds).
     =#

    assert(((header_field_mark > 0 ? 1 : 0) +
            (header_value_mark > 0 ? 1 : 0) +
            (url_mark > 0 ? 1 : 0)  +
            (body_mark > 0 ? 1 : 0) +
            (status_mark > 0 ? 1 : 0)) <= 1)

    header_field_mark > 0 && onheaderfieldbytes(parser, bytes, header_field_mark, min(len, p))
    @debug(PARSING_DEBUG, "onheadervalue 4")
    @debug(PARSING_DEBUG, len)
    @debug(PARSING_DEBUG, p)
    header_value_mark > 0 && onheadervaluebytes(parser, bytes, header_value_mark, min(len, p))
    url_mark > 0 && onurlbytes(parser, bytes, url_mark, min(len, p))
    @debug(PARSING_DEBUG, "this onbody 3")
    body_mark > 0 && onbody(r, maintask, bytes, body_mark, min(len, p - 1))

    parser.state = p_state
    @debug(PARSING_DEBUG, "exiting maybe unfinished...")
    @debug(PARSING_DEBUG, ParsingStateCode(p_state))
    b = p_state == start_state || p_state == s_dead
    he = b | (headersdone || p_state >= s_headers_done)
    m = b | (p_state >= s_message_done)
    return errno, he, m, p >= len ? nothing : String(bytes[p:end])

    @label error
    if errno == HPE_OK
        errno = HPE_UNKNOWN
    end

    parser.state = s_start_req_or_res
    parser.header_state = 0x00
    @debug(PARSING_DEBUG, "exiting due to error...")
    @debug(PARSING_DEBUG, errno)
    return errno, false, false, nothing
end

#= Does the parser need to see an EOF to find the end of the message? =#
function http_message_needs_eof(parser)
    #= See RFC 2616 section 4.4 =#
    if (parser.status == 0 || # Request
        div(parser.status, 100) == 1 || #= 1xx e.g. Continue =#
        parser.status == 204 ||     #= No Content =#
        parser.status == 304 ||     #= Not Modified =#
        parser.flags & F_SKIPBODY > 0)       #= response to a HEAD request =#
        return false
    end

    if (parser.flags & F_CHUNKED > 0) || parser.content_length != ULLONG_MAX
        return false
    end

    return true
end

function http_should_keep_alive(parser)
    if parser.major > 0 && parser.minor > 0
        #= HTTP/1.1 =#
        if parser.flags & F_CONNECTION_CLOSE > 0
            return false
        end
    else
        #= HTTP/1.0 or earlier =#
        if !(parser.flags & F_CONNECTION_KEEP_ALIVE > 0)
            return false
        end
    end

  return !http_message_needs_eof(parser)
end
