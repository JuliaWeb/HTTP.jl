module Handlers

export serve, Router, register!

using URIs
using ..Messages, ..Streams, ..IOExtras, ..Servers, ..Sockets

function streamhandler(handler)
    return function(stream::Stream)
        request::Request = stream.message
        request.body = read(stream)
        closeread(stream)
        request.response::Response = handler(request)
        request.response.request = request
        startwrite(stream)
        write(stream, request.response.body)
        return
    end
end

function serve(f, host=Sockets.localhost, port=8081; stream::Bool=false, kw...)
    return Servers.listen(stream ? f : streamhandler(f), host, port; kw...)
end

# tree-based router handler
mutable struct Variable
    name::String
    pattern::Union{Nothing, Regex}
end

const VARREGEX = r"^{([[:alnum:]]+):?(.*)}$"

function Variable(pattern)
    re = match(VARREGEX, pattern)
    if re === nothing
        error("problem parsing path variable for route: `$pattern`")
    end
    pat = re.captures[2]
    return Variable(re.captures[1], pat == "" ? nothing : Regex(pat))
end

struct Leaf
    method::String
    variables::Vector{Tuple{Int, String}}
    path::String
    handler::Any
end

Base.show(io::IO, x::Leaf) = print(io, "Leaf($(x.method))")

export Node
mutable struct Node
    segment::Union{String, Variable}
    exact::Vector{Node} # sorted alphabetically, all x.segment are String
    conditional::Vector{Node} # unsorted; will be applied in source-order; all x.segment are Regex
    wildcard::Union{Node, Nothing} # unconditional variable or wildcard
    doublestar::Union{Node, Nothing} # /** to match any length of path; must be final segment
    methods::Vector{Leaf}
end

Base.show(io::IO, x::Node) = print(io, "Node($(x.segment))")

isvariable(x) = startswith(x, "{") && endswith(x, "}")
segment(x) = segment == "*" ? String(segment) : isvariable(x) ? Variable(x) : String(x)

Node(x) = Node(x, Node[], Node[], nothing, nothing, Leaf[])
Node() = Node("*")

function find(y, itr; by=identity, eq=(==))
    for (i, x) in enumerate(itr)
        eq(by(x), y) && return i
    end
    return nothing
end

function Base.insert!(node::Node, leaf, segments, i)
    if i > length(segments)
        # time to insert leaf method match node
        j = find(leaf.method, node.methods; by=x->x.method, eq=(x, y) -> x == "*" || x == y)
        if j === nothing
            push!(node.methods, leaf)
        else
            # hmmm, we've seen this route before, warn that we're replacing
            @warn "replacing existing registered route; $(node.methods[j].method) => \"$(node.methods[j].path)\" route with new path = \"$(leaf.path)\""
            node.methods[j] = leaf
        end
        return
    end
    segment = segments[i]
    # @show segment, segment isa Variable
    if segment isa Variable
        # if we're inserting a variable segment, add variable name to leaf vars array
        push!(leaf.variables, (i, segment.name))
    end
    # figure out which kind of node this segment is
    if segment == "*" || (segment isa Variable && segment.pattern === nothing)
        # wildcard node
        if node.wildcard === nothing
            node.wildcard = Node(segment)
        end
        return insert!(node.wildcard, leaf, segments, i + 1)
    elseif segment == "**"
        # double-star node
        if node.doublestar === nothing
            node.doublestar = Node(segment)
        end
        if i < length(segments)
            error("/** double wildcard must be last segment in path")
        end
        return insert!(node.doublestar, leaf, segments, i + 1)
    elseif segment isa Variable
        # conditional node
        # check if we've seen this exact conditional segment before
        j = find(segment.pattern, node.conditional; by=x->x.segment.pattern)
        if j === nothing
            # new pattern
            n = Node(segment)
            push!(node.conditional, n)
        else
            n = node.conditional[j]
        end
        return insert!(n, leaf, segments, i + 1)
    else
        # exact node
        @assert segment isa String
        j = find(segment, node.exact; by=x->x.segment)
        if j === nothing
            # new exact match segment
            n = Node(segment)
            push!(node.exact, n)
            sort!(node.exact; by=x->x.segment)
            return insert!(n, leaf, segments, i + 1)
        else
            # existing exact match segment
            return insert!(node.exact[j], leaf, segments, i + 1)
        end
    end
end

function Base.match(node::Node, params, method, segments, i)
    # @show node.segment, i, segments
    if i > length(segments)
        if isempty(node.methods)
            return nothing
        end
        j = find(method, node.methods; by=x->x.method, eq=(x, y) -> x == "*" || x == y)
        if j === nothing
            # we return missing here so we can return a 405 instead of 404
            # i.e. we matched the route, but there wasn't a matching method
            return missing
        else
            leaf = node.methods[j]
            # @show leaf.variables, segments
            if !isempty(leaf.variables)
                # we have variables to fill in
                for (i, v) in leaf.variables
                    params[v] = segments[i]
                end
            end
            return leaf.handler
        end
    end
    segment = segments[i]
    anymissing = false
    # first check for exact matches
    j = find(segment, node.exact; by=x->x.segment)
    if j !== nothing
        # found an exact match, recurse
        m = match(node.exact[j], params, method, segments, i + 1)
        anymissing = m === missing
        m = coalesce(m, nothing)
        # @show :exact, m
        if m !== nothing
            return m
        end
    end
    # check for conditional matches
    for node in node.conditional
        # @show node.segment.pattern, segment
        if match(node.segment.pattern, segment) !== nothing
            # matched a conditional node, recurse
            m = match(node, params, method, segments, i + 1)
            anymissing = m === missing
            m = coalesce(m, nothing)
            if m !== nothing
                return m
            end
        end
    end
    if node.wildcard !== nothing
        m = match(node.wildcard, params, method, segments, i + 1)
        anymissing = m === missing
        m = coalesce(m, nothing)
        if m !== nothing
            return m
        end
    end
    if node.doublestar !== nothing
        m = match(node.doublestar, params, method, segments, length(segments) + 1)
        anymissing = m === missing
        m = coalesce(m, nothing)
        if m !== nothing
            return m
        end
    end
    return anymissing ? missing : nothing
end

struct Router{T, S}
    _404::T
    _405::S
    routes::Node
end

Router(_404=req -> Response(404), _405=req -> Response(405)) = Router(_404, _405, Node())

function register!(r::Router, method, path, handler)
    segments = map(segment, split(path, '/'; keepempty=false))
    insert!(r.routes, Leaf(method, Tuple{Int, String}[], path, handler), segments, 1)
    return
end

register!(r::Router, path, handler) = register!(r, "*", path, handler)

const Params = Dict{String, String}

function (r::Router)(req)
    url = URI(req.target)
    segments = split(url.path, '/'; keepempty=false)
    params = Params()
    handler = match(r.routes, params, req.method, segments, 1)
    if handler === nothing
        # didn't match a registered route
        return r._404(req)
    elseif handler === missing
        # matched the path, but method not supported
        return r._405(req)
    else
        if !isempty(params)
            req.context[:params] = params
        end
        return handler(req)
    end
end

end # module
