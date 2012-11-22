## HTTP.jl

A Julia library defining the specification and providing the data-types for HTTP servers. It also provides a rudimentary BasicServer that can respond to simple HTTP requests. **The spec and the server are in very active development and significant (breaking) changes should be expected.**

### Installation

Either clone it into one of your LOAD_PATHs (`git clone git://github.com/dirk/HTTP.jl.git HTTP`) or install it via Pkg (coming soon, hopefully).

### Other Notes

The current spec is heavily inspired by Ruby's Rack specification. The parser parts of the basic server are based off of the WEBrick Ruby HTTP server.
