# HttpCommon.jl

[![Build Status](https://travis-ci.org/JuliaLang/HttpCommon.jl.svg?branch=master)](https://travis-ci.org/JuliaLang/HttpCommon.jl)
[![Coverage Status](https://img.shields.io/coveralls/JuliaLang/HttpCommon.jl.svg)](https://coveralls.io/r/JuliaLang/HttpCommon.jl)

**Installation**: `julia> Pkg.add("HttpCommon")`

This package provides types and helper functions for dealing with the HTTP protocol in Julia:

* types to represent `Request`s, `Response`s, and `Headers`
* a dictionary of `STATUS_CODES`
    (maps integer codes to string descriptions; covers all the codes from the RFCs)
* a bitmask representation of HTTP request methods
* a function to `escapeHTML` in a `String`
* a pair of functions to `encodeURI` and `decodeURI`
* a function to turn a query string from a url into a `Dict{String,String}`


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
