Handle `Http` requests in Julia!

## Installation/Setup

This is not yet a real Julia package, so you'll need to install a few things by hand.
Go to your `~/.julia/` directory and run:

~~~~
git clone git://github.com/hackerschool/HttpParser.jl.git
git clone git://github.com/hackerschool/Httplib.jl.git
git clone git://github.com/hackerschool/HttpServer.jl.git
git clone git://github.com/hackerschool/Websockets.jl.git
~~~~

You will also need libhttp-parser,
so you should follow the directions in
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
