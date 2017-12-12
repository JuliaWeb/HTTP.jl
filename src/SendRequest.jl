module SendRequest

struct MessageLayer{T} end
export MessageLayer

struct ConnectLayer{T} end
export ConnectLayer

import ..HTTP.RequestStack.request

using ..URIs
using ..Messages

using ..Connect
using ..IOExtras
using MbedTLS.SSLContext


import ..@debug, ..DEBUG_LEVEL


"""
    writeandread(::IO, ::Request, ::Response)

Send a `Request` and receive a `Response`.
"""

function writeandread(io::IO, req::Request, res::Response)

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
    request(::IO, ::Request, ::Response)

Send a `Request` and receive a `Response`.
"""

function request(io::IO, req::Request, res::Response)

    # Run request in a background task if response body is a stream...
    if isstream(res.body)
        @schedule writeandread(io, req, res)
        waitforheaders(res)
        return res
    end
        
    return writeandread(io, req, res)
end


"""
    request(::URI, ::Request, ::Response)

Get a `Connection` for a `URI`, send a `Request` and fill in a `Response`.
"""


function request(::Type{ConnectLayer{Connection}},
                 uri::URI, req::Request, res::Response; kw...) where Connection

    # Get a connection from the pool...
    T = uri.scheme == "https" ? SSLContext : TCPSocket
    io = getconnection(Connection{T}, uri.host, uri.port; kw...)

    return request(io, req, res)
end


"""
    request(method, uri [, headers=[] [, body="" ]; kw args...)

Execute a `Request` and return a `Response`.

kw args:

- `parent=` optionally set a parent `Response`.

- `response_stream=` optional `IO` stream for response body.


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

function request(::Type{MessageLayer{Next}},
                 method::String, uri, headers=[], body="";
                 bodylength=Messages.Bodies.unknownlength,
                 parent=nothing,
                 response_stream=nothing,
                 kw...) where Next

    u = URI(uri)
    url = method == "CONNECT" ? hostport(u) : resource(u)

    req = Request(method, url, headers, Body(body, bodylength);
                  parent=parent)

    defaultheader(req, "Host" => u.host)
    setlengthheader(req)

    res = Response(body=Body(response_stream), parent=req)

    return request(Next, u, req, res; kw...)
end


end # module SendRequest
