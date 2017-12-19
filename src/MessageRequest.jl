module MessageRequest

import ..Layer, ..RequestStack.request
using ..URIs
using ..Messages

struct MessageLayer{Next <: Layer} <: Layer end
export MessageLayer


"""
    request(MessageLayer, method, uri [, headers=[] [, body="" ]; kw args...)

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
                 method::String, uri, headers, body::Body, response_body::Body;
                 parent=nothing, kw...) where Next

    u = URI(uri)
    url = method == "CONNECT" ? hostport(u) : resource(u)

    req = Request(method, url, headers, body; parent=parent)

    defaultheader(req, "Host" => u.host)
    setlengthheader(req)

    res = Response(body=response_body, parent=req)

    return request(Next, u, req, res; kw...)
end


end # module MessageRequest
