module TestRequest

using HTTP

function testinitiallayer(handler)
    return function(ctx, m, url, h, b; httptestlayer=Ref(false), kw...)
        httptestlayer[] = true
        return handler(ctx, m, url, h, b; kw...)
    end
end

function testrequestlayer(handler)
    return function(ctx, req; httptestlayer=Ref(false), kw...)
        httptestlayer[] = true
        return handler(ctx, req; kw...)
    end
end

function teststreamlayer(handler)
    return function(ctx, stream; httptestlayer=Ref(false), kw...)
        httptestlayer[] = true
        return handler(ctx, stream; kw...)
    end
end

HTTP.@client (testinitiallayer,) (testrequestlayer,) (teststreamlayer,)

end
