# Requests.jl

An HTTP client written in Julia. Uses `joyent/http-parser` via [HttpParser.jl](https://github.com/JuliaWeb/HttpParser.jl).

[![Build Status](https://travis-ci.org/JuliaWeb/Requests.jl.svg?branch=master)](https://travis-ci.org/JuliaWeb/Requests.jl)
[![codecov.io](http://codecov.io/github/JuliaWeb/Requests.jl/coverage.svg?branch=master)](http://codecov.io/github/JuliaWeb/Requests.jl?branch=master)

[![Requests](http://pkg.julialang.org/badges/Requests_0.3.svg)](http://pkg.julialang.org/?pkg=Requests&ver=0.3)
[![Requests](http://pkg.julialang.org/badges/Requests_0.4.svg)](http://pkg.julialang.org/?pkg=Requests&ver=0.4)

## Quickstart

```julia
julia> Pkg.add("Requests")

julia> using Requests
julia> import Requests: get, post, put, delete, options
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
get("http://httpbin.org/get"; query = Dict("title" => "page1"))
get("http://httpbin.org/get"; query = Dict("multi" => ["value1", "value2"]))
```

### Add plain text data

```julia
post("http://httpbin.org/post"; data = "Hello World")
```

### Add JSON data

```julia
post("http://httpbin.org/post"; json = Dict("id" => "1fc80620-7fd3-11e3-80a5"))
```

### Add form-encoded data

```julia
post("http://httpbin.org/post"; data=Dict(email=>"a", pw=>"b"))
```

### Set headers and cookies

```julia
post("http://httpbin.org/post"; headers = Dict("Date" => "Tue, 15 Nov 1994 08:12:31 GMT"),
                                cookies = Dict("sessionkey" => "abc"))
```

HTTP basic authentication is parsed and set as a proper `Authorization` header from the URI:

```julia
post("http://username:password@httpbin.org/post")
```


### Set a timeout
This will throw an error if more than 500ms goes by without receiving any
new bytes from the server.

```julia
get("http://httpbin.org/get"; timeout = .5)    # timeout = Dates.Millisecond(500) will also work
```

### Controls redirects
By default, redirects will be followed. `max_redirects` and `allow_redirects` control this behavior.

```julia
get("http://httpbin.org/redirect/3"; max_redirects=2)  # Throws an error

# Returns a response redirecting the client to "www.google.com"
get("http://google.com"; allow_redirects=false)  
```

### File upload

The three different ways to upload a file called `test.jl` (yes this uploads the
same file three times).

```julia
    filename = "test.jl"
    post("http://httpbin.org/post"; files = [
      FileParam(readall(filename),"text/julia","file1","file1.jl"),
      FileParam(open(filename,"r"),"text/julia","file2","file2.jl",true),
      FileParam(IOBuffer(readall(filename)),"text/julia","file3","file3.jl"),
      ])
    ])
```

FileParam has the following constructors:
```julia
    immutable FileParam
        file::Union{IO,Base.File,AbstractString,Vector{UInt8}}     # The file
        # The content type (default: "", which is interpreted as text/plain serverside)
        ContentType::ASCIIString
        name::ASCIIString                                  # The fieldname (in a form)
        filename::ASCIIString                              # The filename (of the actual file)
        # Whether or not to close the file when the request is done
        close::Bool
    end

    FileParam(str::Union{AbstractString,Vector{UInt8}},ContentType="",name="",filename="")
    FileParam(io::IO,ContentType="",name="",filename="",close::Bool=false)

```

### Inspect responses

Via accessors (preferred):
```julia
readall(::Response)         # Get the payload of the response as a string
readbytes(::Response)       # Get the payload as a byte array
Requests.json(::Response)   # Parse a JSON-encoded response into a Julia object
statuscode(::Response)      # Get the HTTP status code
headers(::Response)         # A dictionary from response header fields to values
cookies(::Response)         # A dictionary from cookie names set by the server to Cookie objects
requestfor(::Response)      # Returns the request that generated the given response
Requests.history(::Response)# Returns the history of redirects that generated the given response.
```

or directly through the Response type fields:
```julia
type Response
    status::Int
    headers::Headers
    cookies::Cookies
    data::Vector{UInt8}
    request::Nullable{Request}
    history::Vector{Response}
end
```

### Saving responses

```julia
cat = get("https://upload.wikimedia.org/wikipedia/commons/8/8e/Termografia_kot.jpg")
save(cat, "catpic.jpg")  # Save the payload to a file
view(cat)  # View the payload using your system's default applciation for its mimetype
```


### Streaming API

Write bytes to disk as they are received:

```julia
stream = Requests.get_streaming("https://upload.wikimedia.org/wikipedia/commons/9/99/Black_cat_being_snowed_on.jpg")

open("cat.jpg", "w") do file
  while !eof(stream)
    write(file, readavailable(stream))
  end
end
```

Stream out data of potentially unknown length using chunked encoding:
```julia
stream = Requests.post_streaming("http://htpbin.org/post",
  headers=Dict("Transfer-Encoding"=>"chunked"), write_body=false)  
# `write_body=false` causes `post_streaming` to only write the headers, allowing you the chance to write the body manually
for data_chunk in ["first", "second"]
    write_chunked(stream, data_chunk)
end
write_chunked(stream, "")  # Signal that the body is complete

response = readall(stream)  # Get back the server's response

```
