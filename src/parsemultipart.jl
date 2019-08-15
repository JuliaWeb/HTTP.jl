const CR_BYTE = 0x0d # \r
const LF_BYTE = 0x0a # \n
const DASH_BYTE = 0x2d # -
const HTAB_BYTE = 0x09 # \t
const SPACE_BYTE = 0x20
const RETURN_BYTES = [CR_BYTE, LF_BYTE]

const FORMDATA_REGEX = r"Content-Disposition: form-data"
const NAME_REGEX = r" name=\"(.*?)\""
const FILENAME_REGEX = r" filename=\"(.*?)\""
const CONTENTTYPE_REGEX = r"Content-Type: (\S*)"

"""
Returns the first and last index of the boundary delimiting a part, and if the discovered
boundary is the terminating boundary.
"""
function find_boundary(bytes::AbstractVector{UInt8}, boundaryDelimiter::AbstractVector{UInt8}; start::Int = 1)
    # The boundary delimiter line is prepended with two '-' characters
    # The boundary delimiter line starts on a new line, so must be preceded by a \r\n.
    # The boundary delimiter line ends with \r\n, and can have "optional linear whitespace" between
    # the end of the boundary delimiter, and the \r\n.
    # The last boundary delimiter line has an additional '--' at the end of the boundary delimiter
    # [RFC2046 5.1.1](https://tools.ietf.org/html/rfc2046#section-5.1.1)

    i = start
    endIndex = i+length(boundaryDelimiter)-1
    while endIndex <= length(bytes)
        if bytes[i:endIndex] == boundaryDelimiter
            # boundary delimiter line start on a new line ...
            if i > 1
                (i == 2 || bytes[i-2] != CR_BYTE || bytes[i-1] != LF_BYTE) && error("boundary delimiter found, but it was not the start of a line")
                # the CRLF preceding the boundary delimiter is "conceptually attached
                # to the boundary", so account for this with the index
                i-=2
            end

            # need to check if there are enough characters for the CRLF or for two dashes
            endIndex < length(bytes)-1 || error("boundary delimiter found, but did not end with new line")

            isTerminatingDelimiter = bytes[endIndex+1] == DASH_BYTE && bytes[endIndex+2] == DASH_BYTE
            isTerminatingDelimiter && (endIndex+=2)

            # ... there can be arbitrary SP and HTAB space between the boundary delimiter ...
            while (endIndex < length(bytes) && (bytes[endIndex+1] in [HTAB_BYTE, SPACE_BYTE])) endIndex+=1 end
            # ... and ends with a new line
            (endIndex < length(bytes)-1) && bytes[endIndex+1] == CR_BYTE && bytes[endIndex+2] == LF_BYTE || error("boundary delimiter found, but did not end with new line")
            endIndex += 2

            return (isTerminatingDelimiter, i, endIndex)
        end

        i += 1
        endIndex += 1
    end

    error("boundary delimiter not found")
end

function find_boundaries(bytes::AbstractVector{UInt8}, boundary::AbstractVector{UInt8}; start = 1)
    idxs = []
    while true
        (isTerminatingDelimiter, i, endIndex) = find_boundary(bytes, boundary; start = start)
        push!(idxs, (i, endIndex))
        isTerminatingDelimiter && break
        start = endIndex + 1
    end
    return idxs
end

function find_returns(bytes::AbstractVector{UInt8})
    l = length(bytes)
    i = 1
    returns = UInt8[]
    while i <= l
        @inbounds byte = bytes[i]
        if byte in RETURN_BYTES
            push!(returns, byte)
            if i==l || !(bytes[i+1] in RETURN_BYTES)
                len = length(returns)
                uniquelen = length(unique(returns))
                len >= 2 * uniquelen && return [i-len, i]
            end
        else
            isempty(returns) || empty!(returns)
        end
        i += 1
    end
    nothing
end

function chunk2Multipart(chunk)
    @warn "" String(copy(chunk))
    i = find_returns(chunk)
    isnothing(i) && return
    description = String(view(chunk, 1:i[1]))
    content = view(chunk, i[2]+1:lastindex(chunk))

    occursin(FORMDATA_REGEX, description) || return # Specifying content disposition is mandatory

    match_name        = match(NAME_REGEX, description)
    match_filename    = match(FILENAME_REGEX, description)
    match_contenttype = match(CONTENTTYPE_REGEX, description)

    name        = !isnothing(match_name) ? match_name[1] : return # Specifying name is mandatory
    filename    = !isnothing(match_filename) ? match_filename[1] : nothing
    contenttype = !isnothing(match_contenttype) ? match_contenttype[1] : "text/plain" # if content_type is not specified, the default text/plain is assumed

    return Multipart(filename, IOBuffer(content), contenttype, "", name)
end

function parse_multipart_body(body::AbstractVector{UInt8}, boundary::AbstractString)::Vector{Multipart}
    multiparts = Multipart[]
    idxs = find_boundaries(body, IOBuffer("--$(boundary)").data)
    length(idxs) > 1 || (return multiparts)

    for i in 1:length(idxs)-1
        chunk = view(body, idxs[i][2]+1:idxs[i+1][1]-1)
        push!(multiparts, chunk2Multipart(chunk))
    end
    return multiparts
end


"""
The order of the multipart form data in the request should be preserved
[RFC7578 5.2](https://tools.ietf.org/html/rfc7578#section-5.2).

The boundary delimiter MUST NOT appear inside any of the encapsulated parts. Note
that the boundary delimiter does not need to have '-' characters, but a line using
the boundary delimiter will start with '--' and end in \r\n.
[RFC2046 5.1](https://tools.ietf.org/html/rfc2046#section-5.1.1)
"""
function parse_multipart_form(req::Request)::Vector{Multipart}
    # parse boundary from Content-Type
    m = match(r"multipart/form-data; boundary=(.*)$", req["Content-Type"])
    isnothing(m) && return nothing

    boundaryDelimiter = m[1]

    # [RFC2046 5.1.1](https://tools.ietf.org/html/rfc2046#section-5.1.1)
    length(boundaryDelimiter) > 70 && error("boundary delimiter must not be greater than 70 characters")

    parse_multipart_body(payload(req), boundaryDelimiter)
end
