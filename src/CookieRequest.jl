module CookieRequest

import ..Dates
using URIs
using ..Cookies
using ..Messages: Request, ascii_lc_isequal, header, setheader
import ..@debug, ..DEBUG_LEVEL, ..access_threaded

# default global cookie jar
const COOKIEJAR = CookieJar()

export cookielayer, COOKIEJAR

"""
    cookielayer(req) -> HTTP.Response

Add locally stored Cookies to the request headers.
Store new Cookies found in the response headers.
"""
function cookielayer(handler)
    return function(req::Request; cookies=true, cookiejar::CookieJar=COOKIEJAR, kw...)
        if cookies === true || (cookies isa AbstractDict && !isempty(cookies))
            url = req.url
            cookiestosend = Cookies.getcookies!(cookiejar, url)
            if !(cookies isa Bool)
                for (name, value) in cookies
                    push!(cookiestosend, Cookie(name, value))
                end
            end
            if !isempty(cookiestosend)
                existingcookie = header(req.headers, "Cookie")
                if existingcookie != "" && haskey(req.context, :includedCookies)
                    # this is a redirect where we previously included cookies
                    # we want to filter those out to avoid duplicate cookie sending
                    # and the case where a cookie was set to expire from the 1st request
                    previouscookies = Cookies.cookies(req)
                    previouslyincluded = req.context[:includedCookies]
                    filtered = filter(x -> !(x.name in previouslyincluded), previouscookies)
                    existingcookie = stringify("", filtered)
                end
                setheader(req.headers, "Cookie" => stringify(existingcookie, cookiestosend))
                req.context[:includedCookies] = map(x -> x.name, cookiestosend)
            end
            res = handler(req; kw...)
            Cookies.setcookies!(cookiejar, url, res.headers)
            return res
        else
            # skip
            return handler(req; kw...)
        end
    end
end

end # module CookieRequest
