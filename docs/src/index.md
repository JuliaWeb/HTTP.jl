# HTTP.jl Documentation

`HTTP.jl` is a Julia library for HTTP Messages.

[`HTTP.request`](@ref) sends a HTTP Request Message and
returns a Response Message.

```julia
r = HTTP.request("GET", "http://httpbin.org/ip")
println(r.status)
println(String(r.body))
```

[`HTTP.open`](@ref) sends a HTTP Request Message and
opens an `IO` stream from which the Response can be read.

```julia
HTTP.open(:GET, "https://tinyurl.com/bach-cello-suite-1-ogg") do http
    open(`vlc -q --play-and-exit --intf dummy -`, "w") do vlc
        write(vlc, http)
    end
end
```


```@contents
Pages = ["public_interface.md", "internal_architecture.md", "internal_interface.md"]
```
