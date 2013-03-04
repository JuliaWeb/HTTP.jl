## HTTP.jl

A Julia library defining the specification and providing the data-types for HTTP servers. It also provides a rudimentary BasicServer that can respond to simple HTTP requests. **The spec and the server are in very active development and significant (breaking) changes should be expected.**

### Installation

```julia
Pkg.add("HTTP")
```

### Getting Started with HTTP.jl

The first component of HTTP.jl is the `HTTP` module. This provides the base `Request`, `Response`, and `Cookie` types as well as some basic helper methods for working with those types (however, actually parsing requests into `Requests`s is left to server implementations). Check out [HTTP.jl](src/HTTP.jl) for the actual code; it's quite readable.

HTTP.Util (in [HTTP/Util.jl](src/HTTP/Util.jl)) also provides some helper methods for escaping and unescaping data.

### Using BasicServer

Coming soon.

### Other Notes

The current spec is heavily inspired by Ruby's Rack specification. The parser parts of the basic server are based off of the WEBrick Ruby HTTP server.

## Ocean

[Ocean](src/Ocean.jl) is a [Sinatra](http://www.sinatrarb.com/)-like library for creating apps that run on the HTTP.jl API (they can currently only be served using BasicServer).

### Hello World

This will create a basic server on port 8000 that responds with "Hello World" to requests at /.

```julia
require("HTTP/Ocean")

using Ocean

app = new_app()

get(app, "/", function(req, res, _)
  return "Hello World"
end)

BasicServer.bind(8000, binding(app), true)
```

You can also use Ocean without mucking up your scope with `using`:

```julia
require("HTTP/Ocean")

app = Ocean.app()

Ocean.get(app, "/", function(req, res, _)
  return "Hello World"
end)

BasicServer.bind(8000, Ocean.binding(app), true)
```

## Changelog

### 0.0.2 (WIP)
#### Improvements
* New template system(!!!)

### 0.0.1 (2013-02-15)
#### Improvements
* Add cookie creation functionality
* Make `ref` for RegexMatch in `Ocean.Util` work properly.
* Add `Extra` object for route handlers.

#### Fixes
* Make `any` shortcut only create a special `"ANY"` route (instead of separate routes for each request method).

### 0.0.0 (2013-02-07)
* Initial version
