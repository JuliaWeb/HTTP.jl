# HttpCommon.jl

[![Build Status](https://travis-ci.org/JuliaWeb/HttpCommon.jl.svg?branch=master)](https://travis-ci.org/JuliaWeb/HttpCommon.jl)
[![codecov.io](http://codecov.io/github/JuliaWeb/HttpCommon.jl/coverage.svg?branch=master)](http://codecov.io/github/JuliaWeb/HttpCommon.jl?branch=master)

[![HttpCommon](http://pkg.julialang.org/badges/HttpCommon_0.3.svg)](http://pkg.julialang.org/?pkg=HttpCommon&ver=0.3)
[![HttpCommon](http://pkg.julialang.org/badges/HttpCommon_0.4.svg)](http://pkg.julialang.org/?pkg=HttpCommon&ver=0.4)

**Installation**: `julia> Pkg.add("HttpCommon")`

This package provides types and helper functions for dealing with the HTTP protocol in Julia:

* types to represent `Request`s, `Response`s, and `Headers`
* a dictionary of `STATUS_CODES`
    (maps integer codes to string descriptions; covers all the codes from the RFCs)
* a function to `escapeHTML` in a `String`
* a function to turn a query string from a url into a `Dict{String,String}`


## Documentation
### Request

A `Request` represents an HTTP request sent by a client to a server. 

```julia    
type Request
    method::String
    resource::String
    headers::Headers
    data::String
end
```

* `method` is an HTTP methods string ("GET", "PUT", etc)
* `resource` is the url resource requested ("/hello/world")
* `headers` is a `Dict` of field name `String`s to value `String`s
* `data` is the data in the request

### Response

A `Response` represents an HTTP response sent to a client by a server.

```julia
type Response
    status::Int
    headers::Headers
    data::HttpData
    finished::Bool
end
```

* `status` is the HTTP status code (see `STATUS_CODES`) [default: `200`]
* `headers` is the `Dict` of headers [default: `headers()`, see Headers below]
* `data` is the response data (as a `String` or `Array{Uint8}`) [default: `""`]
* `finished` is `true` if the `Reponse` is valid, meaning that it can be converted to an actual HTTP response [default: `false`]

There are a variety of constructors for `Response`, which set sane defaults for unspecified values.

```julia
Response([statuscode::Int])
Response(statuscode::Int,[h::Headers],[d::HttpData])
Response(d::HttpData,[h::Headers])
```

### Headers

`Headers` is a type alias for `Dict{String,String}`.
There is a default constructor, `headers`, to produce a reasonable default set of headers.
The defaults are as follows:

```julia
[ "Server" => "Julia/$VERSION",
  "Content-Type" => "text/html; charset=utf-8",
  "Content-Language" => "en",
  "Date" => Dates.format(now(Dates.UTC),Dates.RFC1123Format)]
```

Where the last setting, `"Date"` uses RFC1123 formatting for dates in HTTP headers.

### STATUS_CODES

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