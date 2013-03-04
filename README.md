## HTTP.jl

A Julia library defining the specification and providing the data-types for HTTP servers. It also provides a rudimentary BasicServer that can respond to simple HTTP requests. **The spec and the server are in very active development and significant (breaking) changes should be expected.**

### Installation

```julia
Pkg.add("HTTP")
```

### Getting started with HTTP.jl

The first component of HTTP.jl is the `HTTP` module. This provides the base `Request`, `Response`, and `Cookie` types as well as some basic helper methods for working with those types (however, actually parsing requests into `Requests`s is left to server implementations). Check out [HTTP.jl](src/HTTP.jl) for the actual code; it's quite readable.

HTTP.Util (in [HTTP/Util.jl](src/HTTP/Util.jl)) also provides some helper methods for escaping and unescaping data.

### Using BasicServer

Coming soon.

### Other notes

The current spec is heavily inspired by Ruby's Rack specification. The parser parts of the basic server are based off of the WEBrick Ruby HTTP server.

## Ocean

[Ocean](src/Ocean.jl) is a [Sinatra](http://www.sinatrarb.com/)-like library for creating apps that run on the HTTP.jl API (they can currently only be served using BasicServer).

### Hello World

This will create a basic server on port 8000 that responds with "Hello World" to requests at `/`.

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

### Route parameters

To capture route parameters format your route as a regular expression with capture groups. For example:

```julia
Ocean.get(app, r"^/(.+)", function(req, res, _)
  return _.params[1]
end)
```

A GET request to `/test` would give the response `test`.

If the route path is a string instead of a regex then `_.params` will be `false`.


### Request data

Let's say we have the following POST handler:

```julia
Ocean.post(app, "/", function(req, res, _)
  println(req.data)
  return "foobar"
end)
```

POSTing the data `test=testing` would result in something like `{"test"=>["testing"]}` being printed to output. Of note is that the value is an array. This is because any key could have multiple values (such as the data `test=testing1&test=testing2`), so for consistency any key in `req.data` will map to an array of values.

Ocean provides the shorthand method `gs` (for `get_single`). To get the first value of the key `"test"` in the data dictionary you would call `v = gs(req.data, "test")` (it will return `false` if the key does not exist). To access this and other utility methods just do `using Ocean.Util` (look at [Ocean/Util.jl](src/Ocean/Util.jl) to see what exactly Ocean.Util provides).

### Redirects

Also provided by Ocean.Util (`using Ocean.Util`) is the `redirect` method. This will set the `Location` header in the response headers and the response status to 302 (default).

```julia
using Ocean.Util

Ocean.get(app, ..., function(req, res, _)
  return redirect(res, "/")
  # To do a 301 redirect:
  # return redirect(res, "/", 301)
end)
```

Redirects are also exposed through Ocean.Extra (see _Using templates_ below):

```julia
Ocean.get(app, ..., function(req, res, _)
  return _.redirect("/")
end)
```

### Templates and files

The third parameter to the request handler (assumed to be `_`) is a Ocean.Extra (type definition [here](src/Ocean.jl#L62)) object that provides some data and functions for common tasks.

#### Reading files

The `_.file(path::String)` method will return a string of the file's contents or throw an error. If the file starts with `/` then it will open it as an absolute path; if it starts with any other string it will open it relative to the directory of the app file. The contents of files read are cached in `app.cache` with the key `_file:$path`. You can disable caching by making the second parameter `false` (eg. `_.file(path, false)`).

#### Using templates

Ocean provides a method in Extra to easily access ejl (embedded Julia) and Mustache template files (for Mustache you must require the Mustache package yourself with `require("Mustache")` or `using Mustache`). It uses the `_.file` method internally to read the path to the file; it also caches the compiled template data in `app.cache` (with the keys `_ejl:$path` and `_mustache:$path`) so that the templates don't have to be recompiled every request.

Rendering an ejl template:

```julia
_.template(:ejl, "view.ejl", {"value" => value})
```

Rendering a Mustache template:

```julia
_.template(:mustache, "view.mustache", {"value" => value})
```

### Getting and setting cookies

Coming soon.

## Changelog

### 0.0.2 (WIP)
#### Improvements
* New template system
* Add Mustache.jl template hooks
* Add cookie handling
* Add `file` and `template` scoped methods to `Extra` objects
* Switch to new evented socket API (and add event-loop-free version of `bind`)

#### Fixes
* Fix error reporting

### 0.0.1 (2013-02-15)
#### Improvements
* Add cookie creation functionality
* Make `ref` for RegexMatch in `Ocean.Util` work properly
* Add `Extra` object for route handlers

#### Fixes
* Make `any` shortcut only create a special `"ANY"` route (instead of separate routes for each request method)

### 0.0.0 (2013-02-07)
* Initial version
