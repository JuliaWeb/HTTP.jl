using HTTP

abstract type Matcher end

mutable struct Route
    handler #TODO: restrict it to interface f(req, res)
    matchers::Array{Matcher}
    function Route(handler, path::String, methods)
        matchers = []
        if path != nothing
            pathmatcher = newpathmatcher(path)
            push!(matchers, pathmatcher)
        end
        if methods != nothing
            methodmatcher = newmethodmatcher(methods)
            push!(matchers, methodmatcher)
        end
        return new(handler, matchers)
    end
end

function matchroute(route::Route, req::HTTP.Request)
    # match for all the matchers (conditions) set for this route
    for m in route.matchers
        if !(matchroute(m, req))
            return false
        end
    end
    return true
end

#######################################
#            Matchers
#######################################

############### Path matcher ###########
struct Pathmatcher <: Matcher
    path::String
    hardcorded::Array{String}
    varnames::Array{String}
    regexp::Regex

    function Pathmatcher(p::String)
        idxs = braces_indexes(p)
        defregexp = "[^/]+"
        pattern = "^"
        iend = 1
        varsn = []
        for i in 1:2:length(idxs)
            staticsegment = p[iend:idxs[i]-1]
            #staticname = appendposition(staticsegment, trunc(Int, i/2+1))
            #push!(hardcorded, staticname)
            iend = idxs[i+1]
            parts = split(p[idxs[i]+1:iend-2], ":")
            name = parts[1]
            tmpregexp = defregexp
            if length(parts) == 2
                tmpregexp = parts[2]
            end
            # build regexp here
            pattern = string(pattern, staticsegment, "(?P<", vargroupname(trunc(Int, i/2)), ">", tmpregexp, ")")
            push!(varsn, name)
        end

        staticsegment = p[iend:end]
        #staticname = appendposition(staticsegment, trunc(Int, i/2+1))
        #push!(hardcorded, staticname)
        # build regexp here
        pattern = string(pattern, staticsegment, "\$")
        pattern = Regex(pattern)
        hardcorded = hardcordednames(p)
        return new(p, hardcorded, varsn, pattern)
    end
    #varregexp::Array{}
end

function matchroute(pathmatcher::Pathmatcher, req::HTTP.Request)
    # for now it supports only hard-coded paths
    reqpath = HTTP.path(HTTP.uri(req))
    return ismatch(pathmatcher.regexp, reqpath)
    #=if reqpath == pathmatcher.path || reqpath == pathmatcher.path[2:end]
        return true
    else
        return false
    end=#
    # returns bool
end

function newpathmatcher(path::String)
    return Pathmatcher(path)
end

# populates the values of the variables from the path
function setvarnames(route::Route, req)
    path = HTTP.path(HTTP.uri(req))
    return extractvarvalues(path, route)
end

############# Method matcher ###########
struct Methodmatcher <: Matcher
    methods::Array{String}
end

function newmethodmatcher(methods::Array{String})
    for (i, v) in enumerate(methods)
        methods[i] = uppercase(methods[i])
    end
    return Methodmatcher(methods)
end

function matchroute(methodmatcher::Methodmatcher, req::HTTP.Request)
    reqmtd = string(HTTP.method(req))
    return (reqmtd in methodmatcher.methods)
end

# util function to get the indexs of the {} braces
function braces_indexes(path::String) #TODO add error checking for unbalanced braces
    idxs = []
    for (i, c) in enumerate(path)
        if c == '{'
            push!(idxs, i)
        elseif c == '}'
            push!(idxs, i+1)
        end
    end
    return idxs
end

# util function to get capturing group name for regular expression
function vargroupname(i::Int)
    return string("v", string(i))
end

function hardcordednames(path::String)
    hardcorded = []
    segments = split(path, "/")[2:end] # ignore "" segment
    for (i, seg) in enumerate(segments)
        if seg[1] != '{' && seg[end] != '}'
            push!(hardcorded, positionprefixname(seg, i))
        end
    end
    return hardcorded
end

function extractvarvalues(path::String, r::Route)
    varvalues = Dict{String, Any}()
    pathmatcheridx = find(x -> typeof(x) == Pathmatcher, r.matchers)
    pathmatcher = r.matchers[pathmatcheridx[1]]
    hardcorded = pathmatcher.hardcorded
    varnames = pathmatcher.varnames
    segments = split(path, "/")[2:end]
    k = 1
    if length(varnames) > 0
        for (i, seg) in enumerate(segments)
            if !(positionprefixname(seg, i) in hardcorded)
                varvalues[varnames[k]] = seg
                k = k + 1
            end
        end
    end
    return varvalues
end

function positionprefixname(s::SubString, pos::Int)
    return string(pos, s)
end
