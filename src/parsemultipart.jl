const CR_BYTE = 0x0d # \r
const LF_BYTE = 0x0a # \n
const DASH_BYTE = 0x2d # -
const HTAB_BYTE = 0x09 # \t
const SPACE_BYTE = 0x20
const RETURN_BYTES = [CR_BYTE, LF_BYTE]

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
    end_index = i+length(boundaryDelimiter)-1
    while end_index <= length(bytes)
        if bytes[i:end_index] == boundaryDelimiter
            # boundary delimiter line start on a new line ...
            if i > 1
                (i == 2 || bytes[i-2] != CR_BYTE || bytes[i-1] != LF_BYTE) && error("boundary delimiter found, but it was not the start of a line")
                # the CRLF preceding the boundary delimiter is "conceptually attached
                # to the boundary", so account for this with the index
                i-=2
            end

            # need to check if there are enough characters for the CRLF or for two dashes
            end_index < length(bytes)-1 || error("boundary delimiter found, but did not end with new line")

            is_terminating_delimiter = bytes[end_index+1] == DASH_BYTE && bytes[end_index+2] == DASH_BYTE
            is_terminating_delimiter && (end_index+=2)

            # ... there can be arbitrary SP and HTAB space between the boundary delimiter ...
            while (end_index < length(bytes) && (bytes[end_index+1] in [HTAB_BYTE, SPACE_BYTE]))
                end_index+=1
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
    delimiter = UInt8[CR_BYTE, LF_BYTE, CR_BYTE, LF_BYTE]
    length(delimiter) > length(bytes) && (return nothing)

    l = length(bytes) - length(delimiter) + 1
    i = 1
    end_index = length(delimiter)
    while (i <= l)
        bytes[i:end_index] == delimiter && (return (1, end_index))
        i += 1
        end_index += 1
    end
    error("no delimiter found separating header from multipart body")
end

"""
    content_disposition_tokenize(str)

Tokenize the "arguments" for the Content-Disposition declaration.  A vector of
strings is returned that contains each token and separator found in the source
string. Tokens are separated by either an equal sign(=) or a semi-colon(;) and
may be quoted or escaped with a backslash(\\). All tokens returned are stripped
of whitespace at the beginning and end of the string, quotes are retained.
"""
function content_disposition_tokenize(str)
    retval = Vector{SubString}()
    start = 1
    quotes = false
    escaped = false

    for offset in eachindex(str)
        if escaped == false
            if quotes == true && str[offset] == '"'
                quotes = false
            elseif str[offset] == '\\'
                escaped = true
            elseif str[offset] == '"'
                quotes = true
            elseif quotes == false && (str[offset] == ';' || str[offset] == '=')
                prev = prevind(str, offset)
                if prev > start
                    push!(retval, strip(SubString(str, start, prev)))
                end
                push!(retval, SubString(str, offset, offset))
                start = nextind(str, offset)
            end
        else
            escaped = false
        end
    end

    if start != lastindex(str)
        push!(retval, strip(SubString(str, start)))
    end

    return retval
end

"""
    content_disposition_extract(str)

Extract all the flags and key/value arguments from the Content-Disposition
line.  The result is returned as an array of tuples.

In the case of a flag the first value of the tuple is false the second value
is the flag and the third value is nothing.

In the case of a key/value argument the first value is true, the second is the
key, and the third is the value (or nothing if no value was specified).
"""
function content_disposition_extract(str)
    retval = Vector{Tuple{Bool, SubString, Union{SubString,Nothing}}}()
    tokens = content_disposition_tokenize(str)
    total  = length(tokens)

    function strip_quotes(val)
        if val[1] == '"' && val[end] == '"'
            SubString(val, 2, lastindex(val) - 1)
        else
            val
        end
    end

    i = 1
    while i < total
        if tokens[i] != ';'
            pair  = (i + 1 <= total && tokens[i + 1] == "=")
            key   = strip_quotes(tokens[i])
            value = (pair && i + 2 <= total && tokens[i + 2] != ";" ? strip_quotes(tokens[i + 2]) : nothing)

            push!(retval, (pair, key, value))

            if pair
                i += 3
            else
                i += 1
            end
        else
            i += 1
        end
    end
    return retval
end

"""
    parse_multipart_chunk(chunk)

Parse a single multi-part chunk into a Multipart object.  This will decode
the header and extract the contents from the byte array.
"""
function parse_multipart_chunk(chunk)
    (startIndex, end_index) = find_header_boundary(chunk)

    headers = String(view(chunk, startIndex:end_index))
    content = view(chunk, end_index+1:lastindex(chunk))

    disposition = match(r"(?i)Content-Disposition: form-data(.*)\r\n", headers)

    if disposition === nothing
        @warn "Content disposition is not specified dropping the chunk." chunk
        return # Specifying content disposition is mandatory
    end

    name = nothing
    filename = nothing

    for (pair, key, value) in content_disposition_extract(disposition[1])
        if pair && key == "name"
            name = value
        elseif pair && key == "filename"
            filename = value
        end
    end

    name === nothing && return

    match_contenttype = match(r"(?i)Content-Type: (\S*[^;\s])", headers)
    contenttype = match_contenttype !== nothing ? match_contenttype[1] : "text/plain" # if content_type is not specified, the default text/plain is assumed

    return Multipart(filename, IOBuffer(content), contenttype, "", name)
end

"""
    parse_multipart_body(body, boundary)::Vector{Multipart}

Parse the multipart body received from the client breaking it into the various
chunks which are returned as an array of Multipart objects.
"""
function parse_multipart_body(body::AbstractVector{UInt8}, boundary::AbstractString)::Vector{Multipart}
    multiparts = Multipart[]
    idxs = find_multipart_boundaries(body, Vector{UInt8}("--$(boundary)"))
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
function parse_multipart_form(req::Request)::Union{Vector{Multipart}, Nothing}
    # parse boundary from Content-Type
    m = match(r"multipart/form-data; boundary=(.*)$", req["Content-Type"])
    m === nothing && return nothing

    boundary_delimiter = m[1]

    # [RFC2046 5.1.1](https://tools.ietf.org/html/rfc2046#section-5.1.1)
    length(boundary_delimiter) > 70 && error("boundary delimiter must not be greater than 70 characters")

    return parse_multipart_body(payload(req), boundary_delimiter)
end
