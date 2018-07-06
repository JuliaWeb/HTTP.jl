function find_boundary(bytes::Vector{UInt8}, str, dashes)
    l = length(bytes)
    i = 1
    cons_dash = 0
    while i+length(str) <= l
        @inbounds cons_dash = (bytes[i] == 0x2d) ? cons_dash + 1 : 0
        if cons_dash >= dashes && bytes[(i+1):(i+length(str))] == str
            return [i-dashes, i+length(str)]
        end
        i += 1
    end
    nothing
end

function find_boundary(body::Vector{UInt8}, boundary)
    m =  match(r"^(-*)(.*)$", boundary)
    m === nothing && return nothing
    d, str = m[1], m[2]
    find_boundary(body, unsafe_wrap(Array{UInt8, 1}, String(str)), length(d))
end

function find_content(bytes::Vector{UInt8})
    l = length(bytes)
    i = 1
    while i <= l-1
        matched = false
        bytes[i] == 0x0d && bytes[i+1] == 0x0d && (matched = true)
        bytes[i] == 0x0a && bytes[i+1] == 0x0a && (matched = true)
        matched && return [i-1, i+1]
        bytes[i] == 0x0d && bytes[i+1] == 0x0a && (i+3 <= l) && bytes[i+2] == 0x0d && bytes[i+3] == 0x0a && (matched = true)
        matched && return [i-1, i+3]

        i += 1
    end
    nothing
end

function parse_multipart_chunk!(chunk, d)
    re = r"(\n){2,}|(\r){2,}|[\r\n]{4,}"
    Parsers.exec(re, chunk) || return nothing
    i, j = re.ovec
    description = String(chunk[1:i])
    content = Parsers.nextbytes(re, chunk)

    v = match(r"Content-Disposition: form-data; name=\"(.*)\"; filename=\"(.*)\"[\r\n]+Content-Type: (\S*)", description)
    if v !== nothing
        push!(d["name"], v[1])
        push!(d["filename"], v[2])
        push!(d["contenttype"], v[3])
    else
        v = match(r"Content-Disposition: form-data; name=\"(.*)\"", description)
        v == nothing && return
        push!(d["name"], v[1])
        push!(d["filename"], nothing)
        push!(d["contenttype"], nothing)
    end

    re = r"(?:[\r\n]*)(?:-*)$"
    Parsers.exec(re, content) && (content = content[1:re.ovec[1]])
    push!(d["content"], content)
end

parse_multipart_body(body, boundary) =
    parse_multipart_body(String(body), boundary)

function parse_multipart_body(body::AbstractString, boundary)
    dict = Dict(
        "name" => String[],
        "filename" => Union{String, Nothing}[],
        "contenttype" => Union{String, Nothing}[],
        "content" => Any[]
    )
    re = Regex(boundary)
    Parsers.exec(re, body) || return nothing
    str = Parsers.nextbytes(re, body)
    while Parsers.exec(re, str)
        chunk = str[1:re.ovec[1]]
        isempty(chunk) || parse_multipart_chunk!(chunk, dict)
        str = Parsers.nextbytes(re, str)
    end
    return dict
end

function parse_multipart_form(req::Request)
    m = match(r"multipart/form-data; boundary=(.*)$", req["Content-Type"])
    m === nothing && return nothing
    parse_multipart_body(req.body, m[1])
end
