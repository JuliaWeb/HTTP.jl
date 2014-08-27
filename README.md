# HttpServer.jl

[![Build Status](https://travis-ci.org/JuliaWeb/HttpServer.jl.svg?branch=master)](https://travis-ci.org/JuliaWeb/HttpServer.jl)
[![Coverage Status](https://img.shields.io/coveralls/JuliaWeb/HttpServer.jl.svg)](https://coveralls.io/r/JuliaWeb/HttpServer.jl)

This is a basic, non-blocking HTTP server in Julia.

You can write a basic application using just this
if you're happy dealing with values representing HTTP requests and responses directly.
For a higher-level view, you could use [Meddle](https://github.com/JuliaWeb/Meddle.jl) or [Morsel](https://github.com/JuliaWeb/Morsel.jl).
If you'd like to use WebSockets as well, you'll need to grab [WebSockets.jl](https://github.com/JuliaWeb/WebSockets.jl).

**Installation**: `Pkg.add("HttpServer")`

To make sure everything is working, you can run 
```
cd ~/.julia/v0.3/HttpServer
julia examples/hello.jl
```
If you open up `localhost:8000/hello/name/` in your browser, you should get a greeting from the server.


## Basic Example:

```julia
using HttpServer

http = HttpHandler() do req::Request, res::Response
    Response( ismatch(r"^/hello/",req.resource) ? string("Hello ", split(req.resource,'/')[3], "!") : 404 )
end

http.events["error"]  = ( client, err ) -> println( err )
http.events["listen"] = ( port )        -> println("Listening on $port...")

server = Server( http )
run( server, 8000 )
```

---

```
:::::::::::::
::         ::
:: Made at ::
::         ::
:::::::::::::
     ::
Hacker School
:::::::::::::
```
