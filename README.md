# HttpServer.jl

[![Build Status](https://travis-ci.org/hackerschool/HttpServer.jl.png)](https://travis-ci.org/hackerschool/HttpServer.jl)

This is a basic, non-blocking HTTP server in Julia.

You can write a basic application using just this
if you're happy dealing with values representing HTTP requests and responses directly.
For a higher-level view, you could use [Meddle](https://github.com/hackerschool/Meddle.jl) or [Morsel](https://github.com/hackerschool/Morsel.jl).
If you'd like to use WebSockets as well, you'll need to grab [WebSockets.jl](https://github.com/hackerschool/WebSockets.jl).

## Installation/Setup

```jl
# in REQUIRE
HttpServer 0.0.1

# in REPL
julia> Pkg2.add("HttpServer")
```

To make sure everything is working, you can `cd` into the `~/.julia/HttpServer.jl/` and run `julia examples/hello.jl`. If you open up `localhost:8000/hello/name/`, you should get a greeting from the server.


## Basic Example:

~~~~.jl
using HttpServer

http = HttpHandler() do req::Request, res::Response
    Response( ismatch(r"^/hello/",req.resource) ? string("Hello ", split(req.resource,'/')[3], "!") : 404 )
end

http.events["error"]  = ( client, err ) -> println( err )
http.events["listen"] = ( port )        -> println("Listening on $port...")

server = Server( http )
run( server, 8000 )
~~~~

~~~~
:::::::::::::
::         ::
:: Made at ::
::         ::
:::::::::::::
     ::
Hacker School
:::::::::::::
~~~~
