This package provides URI parsing according to [RFC 3986](http://tools.ietf.org/html/rfc3986).

The main interaction with the package is through the `URI` constructor, which takes a string argument, e.g.

```julia
	julia> URI("hdfs://user:password@hdfshost:9000/root/folder/file.csv")
	URI(hdfs://user:password@hdfshost:9000/root/folder/file.csv)

	julia> URI("https://user:password@httphost:9000/path1/path2;paramstring?q=a&p=r#frag")
	URI(https://user:password@httphost:9000/path1/path2;paramstring?q=a&p=r#frag)

	julia> URI("news:comp.infosystems.www.servers.unix")
	URI(news:comp.infosystems.www.servers.unix)
```

Additionally, there is a method taking the parts of the URI individuall as well as a 
convenience method taking `host` and `path` which constructs a valid http URL:

```julia
	julia> URI("hdfs","hdfshost",9000,"/root/folder/file.csv","","","user:password")
	URI(hdfs://user:password@hdfshost:9000/root/folder/file.csv)

	julia> URI("google.com","/some/path")
	URI(http://google.com:80/some/path)
```
Afterwards, you may either pass the API struct directly to another package (probably the more common use case) or
extract parts of the URI as follows:

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
	"q=a&p=r

	julia> uri.fragment
	"frag"
```