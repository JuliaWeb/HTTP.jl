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
