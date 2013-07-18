HttpCommon
==========

This package provides types and helper functions for dealing with the HTTP protocl in Julia.

* types to represent `Request`s, `Response`s, and `Headers`
* a dictionary of `STATUS_CODES`
    (maps integer codes to string descriptions; covers all the codes from the RFCs)
* a bitmask representation of HTTP request methods
* a function to `escapeHTML` in a `String`
* a pair of functions to `encodeURI` and `decodeURI`
* a function to turn a query string from a url into a `Dict{String,String}`

# Installation

```jl
# in REQUIRE
HttpCommon 0.0.1

# in REPL
julia> Pkg2.add("HttpCommon")
```

You will need to have Julia installed from source because this code has not been tested in v0.1 at all and probably uses features not found there.

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
