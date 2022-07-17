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
