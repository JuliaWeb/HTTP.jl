function find_boundary(bytes::AbstractVector{UInt8}, str, dashes; start::Int = 1)
    l = length(bytes)
    i = start
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

function remove_trailing(bytes::AbstractVector{UInt8}, charlist::AbstractVector{UInt8})
    i = findlast(in(charlist), bytes)
    j = i !== nothing ? i-1 : lastindex(bytes)
    view(bytes, 1:j)
end

remove_trailing(bytes::AbstractVector{UInt8}, char::UInt8) = remove_trailing(bytes, [char])

function find_returns(bytes::AbstractVector{UInt8})
    l = length(bytes)
    i = 1
    returns = UInt8[]
    returnbytes = [0x0d, 0x0a]
    while i <= l
        @inbounds byte = bytes[i]
        if byte in returnbytes
            push!(returns, byte)
            if i==l || !(bytes[i+1] in returnbytes)
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

    content = remove_trailing(content, 0xd)
    content = remove_trailing(content, [0x0d, 0x0a])
    push!(d["content"], content)
end

function parse_multipart_body(body::Vector{UInt8}, boundary)
    dict = Dict(
        "name" => String[],
        "filename" => Union{String, Nothing}[],
        "contenttype" => Union{String, Nothing}[],
        "content" => Any[]
    )
    idxs = find_boundaries(body, boundary)
    for i in 1:length(idxs)-1
        chunk = view(body, idxs[i][2]+1:idxs[i+1][1])
        parse_multipart_chunk!(dict, chunk)
    end
    return dict
end

function parse_multipart_form(req::Request)
    m = match(r"multipart/form-data; boundary=(.*)$", req["Content-Type"])
    m === nothing && return nothing
    parse_multipart_body(req.body, m[1])
end
