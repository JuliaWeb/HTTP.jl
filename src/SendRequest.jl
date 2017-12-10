module SendRequest

import ..HTTP

using ..Pairs.getkv
using ..Strings.tocameldash!
using ..URIs
using ..Messages
using ..Bodies

using ..Connections
using ..IOExtras
using MbedTLS.SSLContext

export request

import ..@debug, ..DEBUG_LEVEL


"""
    request(::IO, ::Request, ::Response)

Send a `Request` and fill in a `Response`.
"""

function request(io::IO, req::Request, res::Response)

    try                                 ;@debug 1 "write to: $io\n$req"
        write(io, req)
        closewrite(io)
        read!(io, res)
        closeread(io)                   ;@debug 2 "read from: $io\n$res"
    catch e
        @schedule close(io)
        rethrow(e)
    end

    return res
end


"""
    request(::URI, ::Request, ::Response)

Get a `Connection` for a `URI`, send a `Request` and fill in a `Response`.
"""

function request(uri::URI, req::Request, res::Response; kw...)

    defaultheader(req, "Host" => uri.host)
    setlengthheader(req, getkv(kw, :body_length, -1))

    # Get a connection from the pool...
    T = uri.scheme == "https" ? SSLContext : TCPSocket
    if getkv(kw, :use_connection_pool, true)
        T = Connections.Connection{T}
    end
    io = getconnection(T, uri.host, uri.port)

    # Run request in a background task if response body is a stream...
    if isstream(res.body)
        @schedule request(io, req, res)
        waitforheaders(res)
        return res
    end
        
    return request(io, req, res)
end


"""
    request(method, uri [, headers=[] [, body="" ]; kw args...)

Execute a `Request` and return a `Response`.

`parent=` optionally set a parent `Response`.

`response_stream=` optional `IO` stream for response body.


e.g. use a stream as a request body:

```
io = open("request", "r")
r = request("POST", "http://httpbin.org/post", [], io)
```

e.g. send a response body to a stream:

```
io = open("response_file", "w")
r = request("GET", "http://httpbin.org/stream/100", response_stream=io)
println(stat("response_file").size)
0
sleep(1)
println(stat("response_file").size)
14990
```
"""

function request(method::String, uri, headers=[], body="";
                 parent=nothing,
                 response_stream=nothing,
                 kw...)

    u = URI(uri)

    req = Request(method,
                  method == "CONNECT" ? hostport(u) : resource(u),
                  headers,
                  Body(body);
                  parent=parent)

    res = Response(body=Body(response_stream), parent=req)

    request(u, req, res; kw...)

    if getkv(kw, :canonicalizeheaders, false)
        res.headers = canonicalizeheaders(res.headers)
    end

    # Redirect request to new location for: 301 Moved Permanently, 302 Found,
    # 307 Temporary Redirect, and 308 Permanent Redirect...
    if (isredirect(res)
    &&  parentcount(res) < getkv(kw, :maxredirects, 3)
    &&  header(res, "Location") != ""
    &&  method != "HEAD") #FIXME why not redirect HEAD?

        return redirect(method, absuri(header(res, "Location"), uri), headers, body;
                        parent=res, response_stream=response_stream, kw...)
    end

    # Throw StatusError for non Status-2xx Response Messages...
    if iserror(res) && getkv(kw, :throw_status_errors, true)
        throw(HTTP.StatusError(res))
    end

    return res
end


function redirect(method, uri, headers, body; kw...)

    if getkv(kw, :forwardheaders, true)
        headers = filter((k,v)->!(k in ("Host", "Cookie")), headers)
    else
        headers = []
    end

    return request(method, uri, headers, body; kw...)
end


canonicalizeheaders{T}(h::T) = T([tocameldash!(k) => v for (k,v) in h])


end # module SendRequest
