module MultiPartParsing

import ..access_threaded
using ..Messages, ..Forms, ..Parsers

export parse_multipart_form

const CR_BYTE = 0x0d # \r
const LF_BYTE = 0x0a # \n
const DASH_BYTE = 0x2d # -
const HTAB_BYTE = 0x09 # \t
const SPACE_BYTE = 0x20
const SEMICOLON_BYTE = UInt8(';')
const CRLFCRLF = (CR_BYTE, LF_BYTE, CR_BYTE, LF_BYTE)

"compare byte buffer `a` from index `i` to index `j` with `b` and check if they are byte-equal"
function byte_buffers_eq(a, i, j, b)
    l = 1
    @inbounds for k = i:j
        a[k] == b[l] || return false
        l += 1
    end
    return true
end

"""
    find_multipart_boundary(bytes, boundaryDelimiter; start::Int=1)

Find the first and last index of the next boundary delimiting a part, and if
the discovered boundary is the terminating boundary.
"""
function find_multipart_boundary(bytes::AbstractVector{UInt8}, boundaryDelimiter::AbstractVector{UInt8}; start::Int=1)
    # The boundary delimiter line is prepended with two '-' characters
    # The boundary delimiter line starts on a new line, so must be preceded by a \r\n.
    # The boundary delimiter line ends with \r\n, and can have "optional linear whitespace" between
    # the end of the boundary delimiter, and the \r\n.
    # The last boundary delimiter line has an additional '--' at the end of the boundary delimiter
    # [RFC2046 5.1.1](https://tools.ietf.org/html/rfc2046#section-5.1.1)

    i = start
    end_index = i + length(boundaryDelimiter) + 1
    while end_index <= length(bytes)
        if bytes[i] == DASH_BYTE && bytes[i + 1] == DASH_BYTE && byte_buffers_eq(bytes, i + 2, end_index, boundaryDelimiter)
            # boundary delimiter line start on a new line ...
            if i > 1
                (i == 2 || bytes[i-2] != CR_BYTE || bytes[i-1] != LF_BYTE) && error("boundary delimiter found, but it was not the start of a line")
                # the CRLF preceding the boundary delimiter is "conceptually attached
                # to the boundary", so account for this with the index
                i -= 2
            end

            # need to check if there are enough characters for the CRLF or for two dashes
            end_index < length(bytes)-1 || error("boundary delimiter found, but did not end with new line")

            is_terminating_delimiter = bytes[end_index+1] == DASH_BYTE && bytes[end_index+2] == DASH_BYTE
            is_terminating_delimiter && (end_index += 2)

            # ... there can be arbitrary SP and HTAB space between the boundary delimiter ...
            while end_index < length(bytes) && (bytes[end_index+1] in (HTAB_BYTE, SPACE_BYTE))
                end_index += 1
            end
            # ... and ends with a new line
            newlineEnd = end_index < length(bytes)-1 &&
                         bytes[end_index+1] == CR_BYTE &&
                         bytes[end_index+2] == LF_BYTE
            if !newlineEnd
                error("boundary delimiter found, but did not end with new line")
            end

            end_index += 2

            return (is_terminating_delimiter, i, end_index)
        end

        i += 1
        end_index += 1
    end

    error("boundary delimiter not found")
end

"""
    find_multipart_boundaries(bytes, boundary; start=1)

Find the start and end indexes of all the parts of the multipart object.  Ultimately this method is
looking for the data between the boundary delimiters in the byte array.  A vector containing all
the start/end pairs is returned.
"""
function find_multipart_boundaries(bytes::AbstractVector{UInt8}, boundary::AbstractVector{UInt8}; start=1)
    idxs = Tuple{Int, Int}[]
    while true
        (is_terminating_delimiter, i, end_index) = find_multipart_boundary(bytes, boundary; start = start)
        push!(idxs, (i, end_index))
        is_terminating_delimiter && break
        start = end_index + 1
    end
    return idxs
end

"""
    find_header_boundary(bytes)

Find the end of the multipart header in the byte array.  Returns a Tuple with the
start index(1) and the end index. Headers are separated from the body by CRLFCRLF.

[RFC2046 5.1](https://tools.ietf.org/html/rfc2046#section-5.1)
[RFC822 3.1](https://tools.ietf.org/html/rfc822#section-3.1)
"""
function find_header_boundary(bytes::AbstractVector{UInt8})
    length(CRLFCRLF) > length(bytes) && return nothing

    l = length(bytes) - length(CRLFCRLF) + 1
    i = 1
    end_index = length(CRLFCRLF)
    while (i <= l)
        byte_buffers_eq(bytes, i, end_index, CRLFCRLF) && return (1, end_index)
        i += 1
        end_index += 1
    end
    error("no delimiter found separating header from multipart body")
end

const content_disposition_regex = Parsers.RegexAndMatchData[]
function content_disposition_regex_f()
    r = Parsers.RegexAndMatchData(r"^Content-Disposition:[ \t]*form-data;[ \t]*(.*)\r\n"x)
    Parsers.init!(r)
end

const content_disposition_flag_regex = Parsers.RegexAndMatchData[]
function content_disposition_flag_regex_f()
    r = Parsers.RegexAndMatchData(r"""^
    [ \t]*([!#$%&'*+\-.^_`|~[:alnum:]]+);?
    """x)
    Parsers.init!(r)
end

const content_disposition_pair_regex = Parsers.RegexAndMatchData[]
function content_disposition_pair_regex_f()
    r = Parsers.RegexAndMatchData(r"""^
    [ \t]*([!#$%&'*+\-.^_`|~[:alnum:]]+)[ \t]*=[ \t]*"(.*?)";?
    """x)
    Parsers.init!(r)
end

const content_type_regex = Parsers.RegexAndMatchData[]
function content_type_regex_f()
    r = Parsers.RegexAndMatchData(r"(?i)Content-Type: (\S*[^;\s])")
    Parsers.init!(r)
end

"""
    parse_multipart_chunk(chunk)

Parse a single multi-part chunk into a Multipart object.  This will decode
the header and extract the contents from the byte array.
"""
function parse_multipart_chunk(chunk)
    startIndex, end_index = find_header_boundary(chunk)
    header = SubString(unsafe_string(pointer(chunk, startIndex), end_index - startIndex + 1))
    content = view(chunk, end_index+1:lastindex(chunk))

    # find content disposition
    re = access_threaded(content_disposition_regex_f, content_disposition_regex)
    if !Parsers.exec(re, header)
        @warn "Content disposition is not specified dropping the chunk." String(chunk)
        return nothing # Specifying content disposition is mandatory
    end
    content_disposition = Parsers.group(1, re, header)

    re_flag = access_threaded(content_disposition_flag_regex_f, content_disposition_flag_regex)
    re_pair = access_threaded(content_disposition_pair_regex_f, content_disposition_pair_regex)
    name = nothing
    filename = nothing
    while !isempty(content_disposition)
        if Parsers.exec(re_pair, content_disposition)
            key = Parsers.group(1, re_pair, content_disposition)
            value = Parsers.group(2, re_pair, content_disposition)
            if key == "name"
                name = value
            elseif key == "filename"
                filename = value
            else
                # do stuff with other content disposition key-value pairs
            end
            content_disposition = Parsers.nextbytes(re_pair, content_disposition)
        elseif Parsers.exec(re_flag, content_disposition)
            # do stuff with content disposition flags
            content_disposition = Parsers.nextbytes(re_flag, content_disposition)
        else
            break
        end
    end

    name === nothing && return

    re_ct = access_threaded(content_type_regex_f, content_type_regex)
    contenttype = Parsers.exec(re_ct, header) ? Parsers.group(1, re_ct, header) : "text/plain"

    return Multipart(filename, IOBuffer(content), contenttype, "", name)
end

"""
    parse_multipart_body(body, boundary)::Vector{Multipart}

Parse the multipart body received from the client breaking it into the various
chunks which are returned as an array of Multipart objects.
"""
function parse_multipart_body(body::AbstractVector{UInt8}, boundary::AbstractString)::Vector{Multipart}
    multiparts = Multipart[]
    idxs = find_multipart_boundaries(body, codeunits(boundary))
    length(idxs) > 1 || (return multiparts)

    for i in 1:length(idxs)-1
        chunk = view(body, idxs[i][2]+1:idxs[i+1][1]-1)
        push!(multiparts, parse_multipart_chunk(chunk))
    end
    return multiparts
end


"""
    parse_multipart_form(req::Request)::Vector{Multipart}

Parse the full mutipart form submission from the client returning and
array of Multipart objects containing all the data.

The order of the multipart form data in the request should be preserved.
[RFC7578 5.2](https://tools.ietf.org/html/rfc7578#section-5.2).

The boundary delimiter MUST NOT appear inside any of the encapsulated parts. Note
that the boundary delimiter does not need to have '-' characters, but a line using
the boundary delimiter will start with '--' and end in \r\n.
[RFC2046 5.1](https://tools.ietf.org/html/rfc2046#section-5.1.1)
"""
function parse_multipart_form(msg::Message)::Union{Vector{Multipart}, Nothing}
    # parse boundary from Content-Type
    m = match(r"multipart/form-data; boundary=(.*)$", msg["Content-Type"])
    m === nothing && return nothing

    boundary_delimiter = m[1]

    # [RFC2046 5.1.1](https://tools.ietf.org/html/rfc2046#section-5.1.1)
    length(boundary_delimiter) > 70 && error("boundary delimiter must not be greater than 70 characters")

    return parse_multipart_body(payload(msg), boundary_delimiter)
end

function __init__()
    nt = isdefined(Base.Threads, :maxthreadid) ? Threads.maxthreadid() : Threads.nthreads()
    resize!(empty!(content_disposition_regex), nt)
    resize!(empty!(content_disposition_flag_regex), nt)
    resize!(empty!(content_disposition_pair_regex), nt)
    resize!(empty!(content_type_regex), nt)
    return
end

end # module MultiPartParsing
