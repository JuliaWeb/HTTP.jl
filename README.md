
# HTTP

*HTTP client and server functionality for Julia*

| **Documentation**                                                         | **Build Status**                                                                                |
|:-------------------------------------------------------------------------:|:-----------------------------------------------------------------------------------------------:|
| [![][docs-stable-img]][docs-stable-url] [![][docs-dev-img]][docs-dev-url] | [![][travis-img]][travis-url] [![][appveyor-img]][appveyor-url] [![][codecov-img]][codecov-url] |


## Installation

The package can be installed with Julia's package manager,
either by using the Pkg REPL mode (press `]` to enter):
```
pkg> add HTTP
```
or by using Pkg functions
```julia
julia> using Pkg; Pkg.add("HTTP")
```

## Project Status

The package is new and not yet tested in production systems.
Please try it out and report your experience.

The package is tested against Julia 1.0 & current master on Linux, macOS, and Windows.

## Contributing and Questions

Contributions are very welcome, as are feature requests and suggestions. Please open an
[issue][issues-url] if you encounter any problems or would just like to ask a question.


## Client Examples

[`HTTP.request`](https://juliaweb.github.io/HTTP.jl/stable/index.html#HTTP.request-Tuple{String,HTTP.URIs.URI,Array{Pair{SubString{String},SubString{String}},1},Any})
sends a HTTP Request Message and returns a Response Message.

```julia
r = HTTP.request("GET", "http://httpbin.org/ip"; verbose=3)
println(r.status)
println(String(r.body))
```

[`HTTP.open`](https://juliaweb.github.io/HTTP.jl/stable/index.html#HTTP.open)
sends a HTTP Request Message and
opens an `IO` stream from which the Response can be read.

```julia
HTTP.open(:GET, "https://tinyurl.com/bach-cello-suite-1-ogg") do http
    open(`vlc -q --play-and-exit --intf dummy -`, "w") do vlc
        write(vlc, http)
    end
end
```

## Server Examples

[`HTTP.Servers.listen`](https://juliaweb.github.io/HTTP.jl/stable/index.html#HTTP.Servers.listen):

```julia
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
```

[`HTTP.Handlers.serve`](https://juliaweb.github.io/HTTP.jl/stable/index.html#HTTP.Handlers.serve):
```julia
HTTP.serve() do request::HTTP.Request
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

## WebSocket Examples

```julia
julia> @async HTTP.WebSockets.listen("127.0.0.1", UInt16(8081)) do ws
           while !eof(ws)
               data = readavailable(ws)
               write(ws, data)
           end
       end

julia> HTTP.WebSockets.open("ws://127.0.0.1:8081") do ws
           write(ws, "Hello")
           x = readavailable(ws)
           @show x
           println(String(x))
       end;
x = UInt8[0x48, 0x65, 0x6c, 0x6c, 0x6f]
Hello
```

[docs-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[docs-dev-url]: https://JuliaWeb.github.io/HTTP.jl/dev

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
