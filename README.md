# Requests.jl

## Quickstart

```julia
julia> Pkg.clone("https://github.com/forio/Requests.jl")

julia> using Requests
```

### Make a request

```julia
get("http://httpbin.org/get")
post("http://httpbin.org/post")
put("http://httpbin.org/put")
delete("http://httpbin.org/delete")
options("http://httpbin.org/get")
```

### Add query parameters

```julia
get("http://httpbin.org/get"; query = {"title" => "page1"})
```

### Add data

```julia
post("http://httpbin.org/post"; data = {"id" => "1fc80620-7fd3-11e3-80a5"})
```

### Set headers

```julia
post("http://httpbin.org/post"; headers = {"Date" => "Tue, 15 Nov 1994 08:12:31 GMT"})
```

### Inspect responses

```julia
type Response
    status::Int
    headers::Headers
    data::HttpData
    finished::Bool
end
```
