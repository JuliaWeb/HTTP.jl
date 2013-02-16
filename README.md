## HTTP.jl

A Julia library defining the specification and providing the data-types for HTTP servers. It also provides a rudimentary BasicServer that can respond to simple HTTP requests. **The spec and the server are in very active development and significant (breaking) changes should be expected.**

### Installation

`Pkg.add("HTTP")`

### Other Notes

The current spec is heavily inspired by Ruby's Rack specification. The parser parts of the basic server are based off of the WEBrick Ruby HTTP server.

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
