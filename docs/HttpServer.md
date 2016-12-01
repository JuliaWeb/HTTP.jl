# HttpServer

This is a basic, non-blocking HTTP server in Julia.

You can write a web application using just this
if you're happy dealing directly with values representing HTTP requests and responses.

The `Request` and `Response` types come from `HttpCommon`; see that section for documentation.


## Installation/Setup

    :::julia
    julia> Pkg.add("HttpServer")

## Testing Your Installation

1. Move to the `~/.julia/HttpServer.jl/` directory.
2. Run `julia examples/hello.jl`.
3. Open `localhost:8000/hello/name` in a browser.
4. You should see a text greeting from the server in your browser.

## Basic Example:

    :::julia
    using HttpServer

    # Julia's do syntax lets you more easily pass a function as an argument
    http = HttpHandler() do req::Request, res::Response
        # if the requested path starts with `/hello/`, say hello
        # otherwise, return a 404 error
        Response( ismatch(r"^/hello/",req.resource) ? string("Hello ", split(req.resource,'/')[3], "!") : 404 )
    end

    # HttpServer supports setting handlers for particular events
    http.events["error"]  = ( client, err ) -> println( err )
    http.events["listen"] = ( port )        -> println("Listening on $port...")

    server = Server( http ) #create a server from your HttpHandler
    run( server, 8000 ) #never returns
