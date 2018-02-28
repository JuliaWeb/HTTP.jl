
# HTTP

*HTTP client and server functionality for Julia*

| **Documentation**                                                               | **PackageEvaluator**                                            | **Build Status**                                                                                |
|:-------------------------------------------------------------------------------:|:---------------------------------------------------------------:|:-----------------------------------------------------------------------------------------------:|
| [![][docs-stable-img]][docs-stable-url] [![][docs-latest-img]][docs-latest-url] | [![][pkg-0.6-img]][pkg-0.6-url] | [![][travis-img]][travis-url] [![][appveyor-img]][appveyor-url] [![][codecov-img]][codecov-url] |


## Installation

The package is registered in `METADATA.jl` and so can be installed with `Pkg.add`.
```julia
julia> Pkg.add("HTTP")
```

<!-- ## Documentation

- [**STABLE**][docs-stable-url] &mdash; **most recently tagged version of the documentation.**
- [**LATEST**][docs-latest-url] &mdash; *in-development version of the documentation.* -->

## Project Status

The package is new and not yet tested in production systems.
Please try it out and report your experience.

The package is tested against Julia 0.6 & current master on Linux, macOS, and Windows.

## Contributing and Questions

Contributions are very welcome, as are feature requests and suggestions. Please open an
[issue][issues-url] if you encounter any problems or would just like to ask a question.


## Client Examples

[`HTTP.request`](@ref) sends a HTTP Request Message and
returns a Response Message.

```julia
r = HTTP.request("GET", "http://httpbin.org/ip"; verbose=3)
println(r.status)
println(String(r.body))
```

[`HTTP.open`](@ref) sends a HTTP Request Message and
opens an `IO` stream from which the Response can be read.

```julia
HTTP.open("GET", "https://tinyurl.com/bach-cello-suite-1-ogg") do http
    open(`vlc -q --play-and-exit --intf dummy -`, "w") do vlc
        write(vlc, http)
    end
end
```

## Server Examples

```
HTTP.listen() do http::HTTP.Stream
    @show http.message
    @show HTTP.header(http, "Content-Type")
    while !eof(http)
        println("body data: ", String(readavailable(http)))
    end
    setstatus(http, 404)
    setheader(http, "Foo-Header" => "bar")
    startwrite(http)
    write(http, "response body")
    write(http, "more response body")
end

HTTP.listen() do request::HTTP.Request
   @show request
   @show request.method
   @show HTTP.header(request, "Content-Type")
   @show HTTP.payload(request)
   try
       return HTTP.Response("Hello")
   catch e
       return HTTP.Response(404, "Error: $e")
   end
end
```

[docs-latest-img]: https://img.shields.io/badge/docs-latest-blue.svg
[docs-latest-url]: https://JuliaWeb.github.io/HTTP.jl/latest

[docs-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg
[docs-stable-url]: https://JuliaWeb.github.io/HTTP.jl/stable

[travis-img]: https://travis-ci.org/JuliaWeb/HTTP.jl.svg?branch=master
[travis-url]: https://travis-ci.org/JuliaWeb/HTTP.jl

[appveyor-img]: https://ci.appveyor.com/api/projects/status/qdy0vfps9gne3sd7?svg=true
[appveyor-url]: https://ci.appveyor.com/project/quinnj/http-jl

[codecov-img]: https://codecov.io/gh/JuliaWeb/HTTP.jl/branch/master/graph/badge.svg
[codecov-url]: https://codecov.io/gh/JuliaWeb/HTTP.jl

[issues-url]: https://github.com/JuliaWeb/HTTP.jl/issues

[pkg-0.6-img]: http://pkg.julialang.org/badges/HTTP_0.6.svg
[pkg-0.6-url]: http://pkg.julialang.org/?pkg=HTTP
