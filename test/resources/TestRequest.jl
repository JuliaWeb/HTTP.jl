module TestRequest

using HTTP

function testrequestlayer(handler)
    return function(req; httptestlayer=Ref(false), kw...)
        httptestlayer[] = true
        return handler(req; kw...)
    end
end

function teststreamlayer(handler)
    return function(stream; httptestlayer=Ref(false), kw...)
        httptestlayer[] = true
        return handler(stream; kw...)
    end
end

HTTP.@client (testrequestlayer,) (teststreamlayer,)

end

module TestRequest2

using HTTP, Test

function testouterrequestlayer(handler)
    return function(req; check=false, kw...)
        @test !check
        return handler(req; check=true, kw...)
    end
end

function testinnerrequestlayer(handler)
    return function(req; check=false, kw...)
        @test check
        return handler(req; kw...)
    end
end

function testouterstreamlayer(handler)
    return function(req; check=false, kw...)
        @test !check
        return handler(req; check=true, kw...)
    end
end

function testinnerstreamlayer(handler)
    return function(req; check=false, kw...)
        @test check
        return handler(req; kw...)
    end
end

HTTP.@client (first=[testouterrequestlayer], last=[testinnerrequestlayer]) (first=[testouterstreamlayer], last=[testinnerstreamlayer])

end

module ErrorRequest

using HTTP

function throwingrequestlayer(handler)
    return function(req; request_exception=nothing, kw...)
        !isnothing(request_exception) && throw(request_exception)
        return handler(req; kw...)
    end
end

function throwingstreamlayer(handler)
    return function(stream; stream_exception=nothing, kw...)
        !isnothing(stream_exception) && throw(stream_exception)
        return handler(stream; kw...)
    end
end

HTTP.@client (throwingrequestlayer,) (throwingstreamlayer,)

end
