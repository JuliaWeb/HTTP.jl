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
    content_length::UInt64
    fieldbuffer::IOBuffer
    valuebuffer::IOBuffer
    method::HTTP.Method
    major::Int16
    minor::Int16
    url::HTTP.URI
    status::Int32
    headers::Vector{Pair{String,String}}
    body::Ref{FIFOBuffer}
end

Parser() = Parser(start_state, 0x00, 0, 0, 0, IOBuffer(), IOBuffer(), Method(0), 0, 0, HTTP.URI(), 0, Pair{String,String}[], Ref{FIFOBuffer}())

const DEFAULT_PARSER = Parser()

function reset!(p::Parser)
    p.state = start_state
    p.header_state = 0x00
    p.index = 0x00
    p.flags = 0x00
    p.content_length = 0x0000000000000000
    truncate(p.fieldbuffer, 0)
    truncate(p.valuebuffer, 0)
    p.method = Method(0)
    p.major = 0
    p.minor = 0
    p.url = HTTP.URI()
    p.status = 0
    empty!(p.headers)
    p.body = Ref{FIFOBuffer}()
    return
end

isrequest(p::Parser) = p.status == 0

# should we just make a copy of the byte vector for URI here?
function onurl(p::Parser)
    @debug(PARSING_DEBUG, "onurl")
    @debug(PARSING_DEBUG, String(p.valuebuffer))
    @debug(PARSING_DEBUG, p.method)
    url = take!(p.valuebuffer)
    uri = URIs.http_parser_parse_url(url, 1, length(url), p.method == CONNECT)
    @debug(PARSING_DEBUG, uri)
    p.url = uri
    return
end

function onheadervalue(p)
    @debug(PARSING_DEBUG, "onheadervalue")
    v = String(take!(p.fieldbuffer)) => String(take!(p.valuebuffer))
    @debug(PARSING_DEBUG, v)
    push!(p.headers, v)
    return
end

function onbody(p, maintask, bytes, i, j)
    @debug(PARSING_DEBUG, "onbody")
    #@debug(PARSING_DEBUG, String(p.body[]))
    @debug(PARSING_DEBUG, String(bytes[i:j]))
    len = j - i + 1
    #TODO: avoid copying the bytes here? can we somehow write the bytes to a FIFOBuffer more efficiently?
    body = p.body[]
    nb = write(body, bytes, i, j)
    if nb < len # didn't write all available bytes
        if current_task() == maintask
            # main request function hasn't returned yet, so not safe to wait
            body.max += len - nb
            write(body, bytes, i + nb, j)
        else
            while nb < len
                nb += write(body, bytes, i + nb, j)
            end
        end
    end
    @debug(PARSING_DEBUG, String(body))
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
    !headerscomplete && throw(ParsingError("error parsing $T: headers incomplete"))
    if upgrade != nothing
        extra[] = upgrade
    end
    close(r.body)
    return r
end

function parse!(r::Union{Request, Response}, parser, bytes, len=length(bytes);
        method::Method=GET,
        maintask::Task=current_task())::Tuple{ParsingErrorCode, Bool, Bool, Union{Void,String}}

    parser.body[] = r.body
    err, headerscomplete, messagecomplete, upgrade = parse!(parser, bytes, len, method, maintask)

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

macro errorif(cond, err)
    return esc(quote
        $cond && @err($err)
    end)
end

macro err(e)
    return esc(quote
        errno = $e
        @goto error
    end)
end

macro strictcheck(cond)
    return esc(:(strict && @errorif($cond, HPE_STRICT)))
end

function parse!(parser::Parser, bytes::Vector{UInt8}, len::Int64, method::Method, maintask::Task)::Tuple{ParsingErrorCode, Bool, Bool, Union{Void,String}}
    @debug(PARSING_DEBUG, "parse!")
    p_state = parser.state
    errno = HPE_UNKNOWN
    upgrade = headersdone = false
    @debug(PARSING_DEBUG, len)
    @debug(PARSING_DEBUG, ParsingStateCode(p_state))
    if len == 0
        if p_state == s_body_identity_eof
            return HPE_OK, true, true, nothing
        elseif @anyeq(p_state, s_dead, s_start_req_or_res, s_start_res, s_start_req)
            return HPE_OK, false, false, nothing
        else
            return HPE_INVALID_EOF_STATE, false, false, nothing
        end
    end

    p = 0
    while p < len
        @debug(PARSING_DEBUG, "top of while($p < $len)")
        @debug(PARSING_DEBUG, ParsingStateCode(p_state))
        p += 1
        @inbounds ch = Char(bytes[p])
        @debug(PARSING_DEBUG, Base.escape_string(string(ch)))

        if p_state == s_dead
            #= this state is used after a 'Connection: close' message
             # the parser will error out if it reads another message
            =#
            @errorif(ch != CR && ch != LF, HPE_CLOSED_CONNECTION)

        elseif p_state == s_start_req_or_res
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
                parser.method = HEAD
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
            @strictcheck(ch != 'T')
            p_state = s_res_HT

        elseif p_state == s_res_HT
            @strictcheck(ch != 'T')
            p_state = s_res_HTT

        elseif p_state == s_res_HTT
            @strictcheck(ch != 'P')
            p_state = s_res_HTTP

        elseif p_state == s_res_HTTP
            @strictcheck(ch != '/')
            p_state = s_res_first_http_major

        elseif p_state == s_res_first_http_major
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.major = Int16(ch - '0')
            p_state = s_res_http_major

        #= major HTTP version or dot =#
        elseif p_state == s_res_http_major
            if ch == '.'
                p_state = s_res_first_http_minor
                continue
            end
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.major *= Int16(10)
            parser.major += Int16(ch - '0')
            @errorif(parser.major > 999, HPE_INVALID_VERSION)

        #= first digit of minor HTTP version =#
        elseif p_state == s_res_first_http_minor
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.minor = Int16(ch - '0')
            p_state = s_res_http_minor

        #= minor HTTP version or end of request line =#
        elseif p_state == s_res_http_minor
            if ch == ' '
                p_state = s_res_first_status_code
                continue
            end
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.minor *= Int16(10)
            parser.minor += Int16(ch - '0')
            @errorif(parser.minor > 999, HPE_INVALID_VERSION)

        elseif p_state == s_res_first_status_code
            if !isnum(ch)
                ch == ' ' && continue
                @err(HPE_INVALID_STATUS)
            end
            parser.status = Int32(ch - '0')
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
                parser.status *= Int32(10)
                parser.status += Int32(ch - '0')
                @errorif(parser.status > 999, HPE_INVALID_STATUS)
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
            @strictcheck(ch != LF)
            p_state = s_header_field_start

        elseif p_state == s_start_req
            (ch == CR || ch == LF) && continue
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

        elseif p_state == s_req_method
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
            ch == ' ' && continue
            if parser.method == CONNECT
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
                if ch in (' ', CR, LF)
                    @errorif(@anyeq(p_state, s_req_schema, s_req_schema_slash,
                                             s_req_schema_slash_slash,
                                             s_req_server_start),
                             HPE_INVALID_URL)
                    break
                end
                p_state = URIs.parseurlchar(p_state, ch, strict)
                @errorif(p_state == s_dead, HPE_INVALID_URL)
                p += 1
            end

            write(parser.valuebuffer, view(bytes, start:p-1))

            if ch == ' '
                p_state = s_req_http_start
                onurl(parser)
            elseif ch in (CR, LF)
                parser.major = Int16(0)
                parser.minor = Int16(9)
                p_state = ifelse(ch == CR, s_req_line_almost_done, s_header_field_start)
                onurl(parser)
            end

        elseif p_state == s_req_http_start
            if ch == 'H'
                p_state = s_req_http_H
            elseif ch == ' '
            else
                @err(HPE_INVALID_CONSTANT)
            end

        elseif p_state == s_req_http_H
            @strictcheck(ch != 'T')
            p_state = s_req_http_HT

        elseif p_state == s_req_http_HT
            @strictcheck(ch != 'T')
            p_state = s_req_http_HTT

        elseif p_state == s_req_http_HTT
            @strictcheck(ch != 'P')
            p_state = s_req_http_HTTP

        elseif p_state == s_req_http_HTTP
            @strictcheck(ch != '/')
            p_state = s_req_first_http_major

        #= first digit of major HTTP version =#
        elseif p_state == s_req_first_http_major
            @errorif(ch < '1' || ch > '9', HPE_INVALID_VERSION)
            parser.major = Int16(ch - '0')
            p_state = s_req_http_major

        #= major HTTP version or dot =#
        elseif p_state == s_req_http_major
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
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            parser.minor = Int16(ch - '0')
            p_state = s_req_http_minor

        #= minor HTTP version or end of request line =#
        elseif p_state == s_req_http_minor
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
            @errorif(ch != LF, HPE_LF_EXPECTED)
            p_state = s_header_field_start

        elseif p_state == s_header_field_start
            if ch == CR
                p_state = s_headers_almost_done
            elseif ch == LF
                #= they might be just sending \n instead of \r\n so this would be
                 * the second \n to denote the end of headers=#
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
                @debug(PARSING_DEBUG, Base.escape_string(string(ch)))
                c = (!strict && ch == ' ') ? ' ' : tokens[Int(ch)+1]
                if c == Char(0)
                    @errorif(ch != ':', HPE_INVALID_HEADER_TOKEN)
                    break
                end
                h = parser.header_state
                @debug(PARSING_DEBUG, h)
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
                #= connection =#
                elseif h == h_matching_connection
                    parser.index += 1
                    if parser.index > length(CONNECTION) || c != CONNECTION[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(CONNECTION)
                        parser.header_state = h_connection
                    end
                #= proxy-connection =#
                elseif h == h_matching_proxy_connection
                    parser.index += 1
                    if parser.index > length(PROXY_CONNECTION) || c != PROXY_CONNECTION[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(PROXY_CONNECTION)
                        parser.header_state = h_connection
                    end
                #= content-length =#
                elseif h == h_matching_content_length
                    parser.index += 1
                    if parser.index > length(CONTENT_LENGTH) || c != CONTENT_LENGTH[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(CONTENT_LENGTH)
                        parser.header_state = h_content_length
                    end
                #= transfer-encoding =#
                elseif h == h_matching_transfer_encoding
                    parser.index += 1
                    if parser.index > length(TRANSFER_ENCODING) || c != TRANSFER_ENCODING[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(TRANSFER_ENCODING)
                        parser.header_state = h_transfer_encoding
                    end
                #= upgrade =#
                elseif h == h_matching_upgrade
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

            if ch == ':'
                p_state = s_header_value_discard_ws
            else
                @assert tokens[Int(ch)+1] != Char(0) || !strict && ch == ' '
            end
            write(parser.fieldbuffer, view(bytes, start:p-1))

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
            write(parser.valuebuffer, bytes[p])

        elseif p_state == s_header_value
            start = p
            h = parser.header_state
            while p <= len
                @inbounds ch = Char(bytes[p])
                @debug(PARSING_DEBUG, Base.escape_string(string('\'', ch, '\'')))
                @debug(PARSING_DEBUG, strict)
                @debug(PARSING_DEBUG, isheaderchar(ch))
                if ch in (CR, LF)
                    p_state = ch == CR ? s_header_almost_done : s_header_value_lws
                    break
                elseif strict && !isheaderchar(ch)
                    @err(HPE_INVALID_HEADER_TOKEN)
                end

                c = lower(ch)

                @debug(PARSING_DEBUG, h)
                if h == h_general
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

            write(parser.valuebuffer, view(bytes, start:p-1))

            if p_state != s_header_value
                onheadervalue(parser)
            end

        elseif p_state == s_header_almost_done
            @errorif(ch != LF, HPE_LF_EXPECTED)
            p_state = s_header_value_lws

        elseif p_state == s_header_value_lws
            p -= 1
            if ch == ' ' || ch == '\t'
                p_state = s_header_value_start
            else
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
            end

        elseif p_state == s_header_value_discard_ws_almost_done
            @strictcheck(ch != LF)
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

                #= header value was empty =#
                p_state = s_header_field_start
                onheadervalue(parser)
                p -= 1
            end

        elseif p_state == s_headers_almost_done
            @strictcheck(ch != LF)
            p -= 1
            if (parser.flags & F_TRAILING) > 0
                #= End of a chunked request =#
                p_state = s_message_done
                continue
            end

            #= Cannot use chunked encoding and a content-length header together
            per the HTTP specification. =#
            @errorif((parser.flags & F_CHUNKED) > 0 && (parser.flags & F_CONTENTLENGTH) > 0, HPE_UNEXPECTED_CONTENT_LENGTH)

            p_state = s_headers_done

            #= Set this here so that on_headers_complete() callbacks can see it =#
            @debug(PARSING_DEBUG, "checking for upgrade...")
            if (parser.flags & F_UPGRADE > 0) && (parser.flags & F_CONNECTION_UPGRADE > 0)
                upgrade = isrequest(parser) || parser.status == 101
            else
                upgrade = isrequest(parser) && parser.method == CONNECT
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

        elseif p_state == s_headers_done
            @strictcheck(ch != LF)

            hasBody = parser.flags & F_CHUNKED > 0 ||
                (parser.content_length > 0 && parser.content_length != ULLONG_MAX)
            if upgrade && ((isrequest(parser) && parser.method == CONNECT) ||
                                  (parser.flags & F_SKIPBODY) > 0 || !hasBody)
                #= Exit, the rest of the message is in a different protocol. =#
                p_state = ifelse(http_should_keep_alive(parser), start_state, s_dead)
                parser.state = p_state
                return HPE_OK, true, true, String(bytes[p+1:end])
            end

            if parser.flags & F_SKIPBODY > 0
                p_state = ifelse(http_should_keep_alive(parser), start_state, s_dead)
                parser.state = p_state
                return HPE_OK, true, true, nothing
            elseif parser.flags & F_CHUNKED > 0
                #= chunked encoding - ignore Content-Length header =#
                p_state = s_chunk_size_start
            else
                if parser.content_length == 0
                    #= Content-Length header given but zero: Content-Length: 0\r\n =#
                    p_state = ifelse(http_should_keep_alive(parser), start_state, s_dead)
                    parser.state = p_state
                    return HPE_OK, true, true, nothing
                elseif parser.content_length != ULLONG_MAX
                    #= Content-Length header given and non-zero =#
                    p_state = s_body_identity
                else
                    if !http_message_needs_eof(parser)
                        #= Assume content-length 0 - read the next =#
                        p_state = ifelse(http_should_keep_alive(parser), start_state, s_dead)
                        parser.state = p_state
                        return HPE_OK, true, true, p >= len ? nothing : String(bytes[p:end])
                    else
                        #= Read body until EOF =#
                        p_state = s_body_identity_eof
                    end
                end
            end

        elseif p_state == s_body_identity
            to_read = UInt64(min(parser.content_length, len - p + 1))
            assert(parser.content_length != 0 && parser.content_length != ULLONG_MAX)

            onbody(parser, maintask, bytes, p, p + to_read - 1)

            #= The difference between advancing content_length and p is because
            * the latter will automaticaly advance on the next loop iteration.
            * Further, if content_length ends up at 0, we want to see the last
            * byte again for our message complete callback.
            =#
            parser.content_length -= to_read
            p += to_read - 1

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
                p -= 1
            end

        #= read until EOF =#
        elseif p_state == s_body_identity_eof
            onbody(parser, maintask, bytes, p, len)
            p = len

        elseif p_state == s_message_done
            if upgrade
                #= Exit, the rest of the message is in a different protocol. =#
                parser.state = p_state
                return HPE_OK, true, true, String(bytes[p+1:end])
            end
            p = len

        elseif p_state == s_chunk_size_start
            assert(parser.flags & F_CHUNKED > 0)

            unhex_val = unhex[Int(ch)+1]
            @errorif(unhex_val == -1, HPE_INVALID_CHUNK_SIZE)

            parser.content_length = unhex_val
            p_state = s_chunk_size

        elseif p_state == s_chunk_size
            assert(parser.flags & F_CHUNKED > 0)
            if ch == CR
                p_state = s_chunk_size_almost_done
            else
                unhex_val = unhex[Int(ch)+1]
                @debug(PARSING_DEBUG, unhex_val)
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

                #= Overflow? Test against a conservative limit for simplicity. =#
                @debug(PARSING_DEBUG, "this content_length 2")
                @debug(PARSING_DEBUG, Int(parser.content_length))
                if div(ULLONG_MAX - 16, 16) < t
                    @err(HPE_INVALID_CONTENT_LENGTH)
                end
                parser.content_length = t
            end

        elseif p_state == s_chunk_parameters
            assert(parser.flags & F_CHUNKED > 0)
            #= just ignore this shit. TODO check for overflow =#
            if ch == CR
                p_state = s_chunk_size_almost_done
            end

        elseif p_state == s_chunk_size_almost_done
            assert(parser.flags & F_CHUNKED > 0)
            @strictcheck(ch != LF)

            if parser.content_length == 0
                parser.flags |= F_TRAILING
                p_state = s_header_field_start
            else
                p_state = s_chunk_data
            end

        elseif p_state == s_chunk_data
            to_read = UInt64(min(parser.content_length, len - p + 1))

            assert(parser.flags & F_CHUNKED > 0)
            assert(parser.content_length != 0 && parser.content_length != ULLONG_MAX)

            onbody(parser, maintask, bytes, p, p + to_read - 1)

            #= See the explanation in s_body_identity for why the content
            * length and data pointers are managed this way.
            =#
            parser.content_length -= to_read
            p += Int(to_read) - 1

            if parser.content_length == 0
                p_state = s_chunk_data_almost_done
            end

        elseif p_state == s_chunk_data_almost_done
            assert(parser.flags & F_CHUNKED > 0)
            assert(parser.content_length == 0)
            @strictcheck(ch != CR)
            p_state = s_chunk_data_done

        elseif p_state == s_chunk_data_done
            assert(parser.flags & F_CHUNKED > 0)
            @strictcheck(ch != LF)
            p_state = s_chunk_size_start

        else
            error("unhandled state")
        end
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

    parser.state = p_state
    @debug(PARSING_DEBUG, "exiting maybe unfinished...")
    @debug(PARSING_DEBUG, ParsingStateCode(p_state))
    b = p_state == start_state || p_state == s_dead
    he = b | (headersdone || p_state >= s_headers_done)
    m = b | (p_state >= s_message_done)
    return HPE_OK, he, m, p >= len ? nothing : String(bytes[p:end])

    @label error
    parser.state = s_start_req_or_res
    parser.header_state = 0x00
    @debug(PARSING_DEBUG, "exiting due to error...")
    @debug(PARSING_DEBUG, errno)
    return errno, false, false, nothing
end

#= Does the parser need to see an EOF to find the end of the message? =#
function http_message_needs_eof(parser)
    #= See RFC 2616 section 4.4 =#
    if (isrequest(parser) ||
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
