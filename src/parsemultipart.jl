const RETURN_BYTES = [0x0d, 0x0a]
const DASH_BYTE = 0x2d

const FORMDATA_REGEX = r"Content-Disposition: form-data"
const NAME_REGEX = r" name=\"(.*?)\""
const FILENAME_REGEX = r" filename=\"(.*?)\""
const CONTENTTYPE_REGEX = r"Content-Type: (\S*)"

function find_boundary(bytes::AbstractVector{UInt8}, str, dashes; start::Int = 1)
    l = length(bytes)
    i = start
    cons_dash = 0
    while i+length(str) <= l
        @inbounds cons_dash = (bytes[i] == DASH_BYTE) ? cons_dash + 1 : 0
        if cons_dash >= dashes && bytes[(i+1):(i+length(str))] == str
            return [i-dashes, i+length(str)]
        end
        i += 1
    end
    nothing
end

function find_boundaries(bytes::AbstractVector{UInt8}, str, dashes; start = 1)
    idxs = Vector{Int}[]
    j = find_boundary(bytes, str, dashes; start = start)
    while j !== nothing
        push!(idxs, j)
        j = find_boundary(bytes, str, dashes; start = j[2]+1)
    end
    return idxs
end

function find_boundaries(bytes::AbstractVector{UInt8}, boundary; start::Int = 1)
    m =  match(r"^(-*)(.*)$", boundary)
    m === nothing && return nothing
    d, str = m[1], m[2]
    find_boundaries(bytes, unsafe_wrap(Array{UInt8, 1}, String(str)), length(d); start = start)
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

function parse_multipart_chunk!(d, chunk)
    i = find_returns(chunk)
    i == nothing && return
    description = String(view(chunk, 1:i[1]))
    content = view(chunk, i[2]+1:lastindex(chunk))

    occursin(FORMDATA_REGEX, description) || return # Specifying content disposition is mandatory

    match_name        = match(NAME_REGEX, description)
    match_filename    = match(FILENAME_REGEX, description)
    match_contenttype = match(CONTENTTYPE_REGEX, description)

    name        = match_name !== nothing ? match_name[1] : return # Specifying name is mandatory
    filename    = match_filename !== nothing ? match_filename[1] : nothing
    contenttype = match_contenttype !== nothing ? match_contenttype[1] : "text/plain" # if content_type is not specified, the default text/plain is assumed

    # remove trailing \r\n-- characters
    content = view(content, 1:length(content)-4)

    io = IOBuffer()
    write(io, content)
    seekstart(io)
    push!(d, Multipart(filename, io, contenttype, "", name))
end

function parse_multipart_body(body::Vector{UInt8}, boundary)::Vector{Multipart}
    d = Multipart[]
    idxs = find_boundaries(body, boundary)
    for i in 1:length(idxs)-1
        chunk = view(body, idxs[i][2]+1:idxs[i+1][1])
        parse_multipart_chunk!(d, chunk)
    end
    return d
end

"""
The order of the multipart form data in the request should be preserved
[RFC7578 5.2](https://tools.ietf.org/html/rfc7578#section-5.2).
"""
function parse_multipart_form(req::Request)::Vector{Multipart}
    m = match(r"multipart/form-data; boundary=(.*)$", req["Content-Type"])
    isnothing(m) && return nothing
    parse_multipart_body(payload(req), m[1])
end
