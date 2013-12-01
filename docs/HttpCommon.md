# HttpCommon

This package provides types and helper functions for dealing with the HTTP protocol.

* types to represent `Request`s, `Response`s, and `Headers`
* a dictionary of `STATUS_CODES`
    (maps integer codes to string descriptions; covers all the codes from the RFCs)
* a bitmask representation of HTTP request methods
* a function to `escapeHTML` in a `String`
* a pair of functions to `encodeURI` and `decodeURI`
* a function to turn a query string from a url into a `Dict{String,String}`

## Installation

    :::julia
    julia> Pkg.add("HttpCommon")

## Request

A `Request` represents an HTTP request sent by a client to a server. 

    :::julia
    type Request
        method::String
        resource::String
        headers::Headers
        data::String
    end

* `method` is an HTTP methods string ("GET", "PUT", etc)
* `resource` is the url resource requested ("/hello/world")
* `headers` is a `Dict` of field name `String`s to value `String`s
* `data` is the data in the request

## Response

A `Response` represents an HTTP response sent to a client by a server.

    :::julia
    type Response
        status::Int
        headers::Headers
        data::HttpData
        finished::Bool
    end

* `status` is the HTTP status code (see `STATUS_CODES`) [default: `200`]
* `headers` is the `Dict` of headers [default: `headers()`, see Headers below]
* `data` is the response data (as a `String` or `Array{Uint8}`) [default: `""`]
* `finished` is `true` if the `Reponse` is valid, meaning that it can be converted to an actual HTTP response [default: `false`]

There are a variety of constructors for `Response`, which set sane defaults for unspecified values.

    :::julia
    Response([statuscode::Int])
    Response(statuscode::Int,[h::Headers],[d::HttpData])
    Response(d::HttpData,[h::Headers])


## Headers

## STATUS_CODES

## HTTP request methods

## escapeHTML

## encodeURI and decodeURI

## parsequerystring

## RFC1123_datetime([CalendarTime])
