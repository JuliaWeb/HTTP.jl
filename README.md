# URIParser.jl

This Julia package provides URI parsing according to [RFC 3986](http://tools.ietf.org/html/rfc3986).

[![Build Status](https://travis-ci.org/JuliaWeb/URIParser.jl.svg?branch=master)](https://travis-ci.org/JuliaWeb/URIParser.jl)
[![Coverage Status](https://coveralls.io/repos/JuliaWeb/URIParser.jl/badge.svg?branch=master&service=github)](https://coveralls.io/github/JuliaWeb/URIParser.jl?branch=master)
[![URIParser](http://pkg.julialang.org/badges/URIParser_release.svg)](http://pkg.julialang.org/?pkg=URIParser&ver=release)

The main interaction with the package is through the `URI` constructor, which takes a string argument, e.g.

```julia
julia> using URIParser

julia> URI("hdfs://user:password@hdfshost:9000/root/folder/file.csv")
URI(hdfs://user:password@hdfshost:9000/root/folder/file.csv)

julia> URI("https://user:password@httphost:9000/path1/path2;paramstring?q=a&p=r#frag")
URI(https://user:password@httphost:9000/path1/path2;paramstring?q=a&p=r#frag)

julia> URI("news:comp.infosystems.www.servers.unix")
URI(news:comp.infosystems.www.servers.unix)
```

Additionally, there is a method for taking the parts of the URI individually, as well as a convenience method taking `host` and `path` which constructs a valid HTTP URL:

```julia
julia> URI("hdfs","hdfshost",9000,"/root/folder/file.csv","","","user:password")
URI(hdfs://user:password@hdfshost:9000/root/folder/file.csv)

julia> URI("google.com","/some/path")
URI(http://google.com:80/some/path)
```

Afterwards, you may either pass the API struct directly to another package (probably the more common use case) or extract parts of the URI as follows:

```julia
julia> uri = URI("https://user:password@httphost:9000/path1/path2;paramstring?q=a&p=r#frag")
URI(https://user:password@httphost:9000/path1/path2;paramstring?q=a&p=r#frag)

julia> uri.schema
"https"

julia> uri.host
"httphost"

julia> dec(uri.port)
"9000"

julia> uri.path
"/path1/path2;paramstring"

julia> uri.query
"q=a&p=r"

julia> uri.fragment
"frag"

julia> uri.specifies_authority
true
```

The `specifies_authority` may need some extra explanation. The reson for its existence is that RFC 3986 differentiates between empty authorities and missing authorities, but there is not way to distinguish these by just looking at the fields. As an example:

```julia
julia> URI("file:///a/b/c").specifies_authority
true

julia> URI("file:///a/b/c").host
""

julia> URI("file:a/b/c").specifies_authority
false

julia> URI("file:a/b/c").host
""
```

Now, while the `file` schema consideres these to be equivalent, this may not necessarily be true for all schemas and thus the distinction is necessary.
