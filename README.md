# HttpCommon.jl

[![Build Status](https://travis-ci.org/JuliaWeb/HttpCommon.jl.svg?branch=master)](https://travis-ci.org/JuliaWeb/HttpCommon.jl)
[![codecov.io](http://codecov.io/github/JuliaWeb/HttpCommon.jl/coverage.svg?branch=master)](http://codecov.io/github/JuliaWeb/HttpCommon.jl?branch=master)

[![HttpCommon](http://pkg.julialang.org/badges/HttpCommon_0.3.svg)](http://pkg.julialang.org/?pkg=HttpCommon&ver=0.3)
[![HttpCommon](http://pkg.julialang.org/badges/HttpCommon_0.4.svg)](http://pkg.julialang.org/?pkg=HttpCommon&ver=0.4)

**Installation**: `julia> Pkg.add("HttpCommon")`

This package provides types and helper functions for dealing with the HTTP protocol in Julia:

* Types to represent `Headers`, `Request`s, `Cookie`s, and `Response`s
* a dictionary of `STATUS_CODES`
    (maps integer codes to string descriptions; covers all the codes from the RFCs)
* a function to `escapeHTML` in a `String`
* a function to turn a query string from a url into a `Dict{String,String}`


## HTTP Types

#### `Headers`

`Headers` represents the header fields for an HTTP request, and is type alias for `Dict{String,String}`.
There is a default constructor, `headers`, that produces a reasonable default set of headers:
```julia
Dict( "Server"           => "Julia/$VERSION",
      "Content-Type"     => "text/html; charset=utf-8",
      "Content-Language" => "en",
      "Date"             => Dates.format(now(Dates.UTC), Dates.RFC1123Format) )
```


#### `Request`

A `Request` represents an HTTP request sent by a client to a server.
It has five fields:

* `method`: an HTTP methods string (e.g. "GET")
* `resource`: the resource requested (e.g. "/hello/world")
* `headers`: see `Headers` above
* `data`: the data in the request as a vector of bytes


#### `Cookie`

A `Cookie` represents an HTTP cookie. It has three fields:
`name` and `value` are strings, and `attrs` is dictionary
of pairs of strings.


#### Response

A `Response` represents an HTTP response sent to a client by a server.
It has six fields:

* `status`: HTTP status code (see `STATUS_CODES`) [default: `200`]
* `headers`: `Headers` [default: `HttpCommmon.headers()`]
* `cookies`: Dictionary of strings => `Cookie`s
* `data`: the request data as a vector of bytes [default: `UInt8[]`]
* `finished`: `true` if the `Reponse` is valid, meaning that it can be
  converted to an actual HTTP response [default: `false`]
* `requests`: the history of requests that generated the response.
  Can be greater than one if a redirect was involved.

Response has many constructors - use `methods(Response)` for full list.


#### STATUS_CODES

`STATUS_CODES` is a `const` `Dict{Int,String}`.
It maps all the status codes defined in RFC's to their descriptions.

```julia
STATUS_CODES[200] #=> "OK"
STATUS_CODES[404] #=> "Not Found"
STATUS_CODES[418] #=> "I'm a teapot"
STATUS_CODES[500] #=> "Internal Server Error"
```

#### `escapeHTML(i::String)`

Returns a string with special HTML characters escaped: `&, <, >, ", '`


#### `parsequerystring(query::String)`

Convert a valid querystring to a Dict:

```julia
q = "foo=bar&baz=%3Ca%20href%3D%27http%3A%2F%2Fwww.hackershool.com%27%3Ehello%20world%21%3C%2Fa%3E"
parsequerystring(q)
# Dict{ASCIIString,ASCIIString} with 2 entries:
#   "baz" => "<a href='http://www.hackershool.com'>hello world!</a>"
#   "foo" => "bar"
```


---


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