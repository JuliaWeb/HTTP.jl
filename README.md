This is a basic, non-blocking HTTP server in Julia.

You can write a basic application using just this
if you're happy dealing with values representing HTTP requests and responses directly.
For a higher-level view, you could use [Meddle](https://github.com/hackerschool/Meddle.jl) or [Morsel](https://github.com/hackerschool/Morsel.jl).
If you'd like to use WebSockets as well, you'll need to grab [WebSockets.jl](https://github.com/hackerschool/WebSockets.jl).

## Installation/Setup

This is a Julia package, so you just need to run `Pkg.add("HttpServer")` in a Julia repl.
It will install this package and all dependencies in your `~/.julia` directory.

You will also need libhttp-parser, so you should follow the directions in
[HttpParser](https://github.com/hackerschool/HttpParser.jl)'s README.

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
