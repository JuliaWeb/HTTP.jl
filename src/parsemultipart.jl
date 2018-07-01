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

parse_multipart_body(body::AbstractArray{UInt8}, boundary) =
    parse_multipart_body(String(body), boundary)

function parse_multipart_body(body, boundary)
    body = String(body)
    dict = Dict(
        "name" => String[],
        "filename" => Union{String, Void}[],
        "contenttype" => Union{String, Void}[],
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
