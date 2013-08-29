WWWClient.jl
=============

The Http client package provides basic functionality for talking to http servers. 
It does not however, implement any of the features you would find in a browser (e.g.
following redirects or interpreting any part of the response). It's API is extremely simple.

# Usage

To query an HTTP server using the GET method, you may use:
```julia
WWWClient.get("http://example.org")
```
or, equivalently

```julia
WWWClient.get(URL("http://example.org"))
```

WWWClient.jl also natively supports HTTPS albeit it does not do certificate validation yet:
```julia
WWWClient.get(URI("https://example.org")) #Note the https
```

Other methods that are available are:
```julia
WWWClient.post(URI("https://example.org"),data)
WWWClient.delete(URI("https://example.org"))
```

# Getting the package

Currently this package is not listed in METADATA, to get it you will have to use
```
Pkg.clone("https://github.com/loladiro/WWWClient.jl")
```