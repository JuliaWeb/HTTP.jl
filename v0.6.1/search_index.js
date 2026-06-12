var documenterSearchIndex = {"docs": [

{
    "location": "index.html#",
    "page": "Home",
    "title": "Home",
    "category": "page",
    "text": ""
},

{
    "location": "index.html#HTTP.jl-Documentation-1",
    "page": "Home",
    "title": "HTTP.jl Documentation",
    "category": "section",
    "text": "HTTP.jl is a Julia library for HTTP Messages.HTTP.request sends a HTTP Request Message and returns a Response Message.r = HTTP.request(\"GET\", \"http://httpbin.org/ip\")\nprintln(r.status)\nprintln(String(r.body))HTTP.open sends a HTTP Request Message and opens an IO stream from which the Response can be read.HTTP.open(\"GET\", \"https://tinyurl.com/bach-cello-suite-1-ogg\") do http\n    open(`vlc -q --play-and-exit --intf dummy -`, \"w\") do vlc\n        write(vlc, http)\n    end\nend"
},

{
    "location": "index.html#HTTP.request-Tuple{String,HTTP.URIs.URI,Array{Pair{String,String},1},Any}",
    "page": "Home",
    "title": "HTTP.request",
    "category": "Method",
    "text": "HTTP.request(method, url [, headers [, body]]; <keyword arguments>]) -> HTTP.Response\n\nSend a HTTP Request Message and recieve a HTTP Response Message.\n\ne.g.\n\nr = HTTP.request(\"GET\", \"http://httpbin.org/ip\")\nprintln(r.status)\nprintln(String(r.body))\n\nheaders can be any collection where [string(k) => string(v) for (k,v) in headers] yields Vector{Pair}. e.g. a Dict(), a Vector{Tuple}, a Vector{Pair} or an iterator.\n\nbody can take a number of forms:\n\na String, a Vector{UInt8} or any T accepted by write(::IO, ::T)\na collection of String or AbstractVector{UInt8} or IO streams or items of any type T accepted by write(::IO, ::T...)\na readable IO stream or any IO-like type T for which eof(T) and readavailable(T) are defined.\n\nThe HTTP.Response struct contains:\n\nstatus::Int16 e.g. 200\nheaders::Vector{Pair{String,String}}  e.g. [\"Server\" => \"Apache\", \"Content-Type\" => \"text/html\"]\nbody::Vector{UInt8}, the Response Body bytes  (empty if a response_stream was specified in the request).\n\nFunctions HTTP.get, HTTP.put, HTTP.post and HTTP.head are defined as shorthand for HTTP.request(\"GET\", ...), etc.\n\nHTTP.request and HTTP.open also accept optional keyword parameters.\n\ne.g.\n\nHTTP.request(\"GET\", \"http://httpbin.org/ip\"; retries=4, cookies=true)\n\nHTTP.get(\"http://s3.us-east-1.amazonaws.com/\"; aws_authorization=true)\n\nconf = (readtimeout = 10,\n        pipeline_limit = 4,\n        retry = false,\n        redirect = false)\n\nHTTP.get(\"http://httpbin.org/ip\"; conf..)\nHTTP.put(\"http://httpbin.org/put\", [], \"Hello\"; conf..)\n\nURL options\n\nquery = nothing, replaces the query part of url.\n\nStreaming options\n\nresponse_stream = nothing, a writeable IO stream or any IO-like  type T for which write(T, AbstractVector{UInt8}) is defined.\nverbose = 0, set to 1 or 2 for extra message logging.\n\nConnection Pool options\n\nconnection_limit = 8, number of concurrent connections to each host:port.\npipeline_limit = 16, number of concurrent requests per connection.\nreuse_limit = nolimit, number of times a connection is reused after the                          first request.\nsocket_type = TCPSocket\n\nTimeout options\n\nreadtimeout = 60, close the connection if no data is recieved for this many seconds. Use readtimeout = 0 to disable.\n\nRetry options\n\nretry = true, retry idempotent requests in case of error.\nretries = 4, number of times to retry.\nretry_non_idempotent = false, retry non-idempotent requests too. e.g. POST.\n\nRedirect options\n\nredirect = true, follow 3xx redirect responses.\nredirect_limit = 3, number of times to redirect.\nforwardheaders = false, forward original headers on redirect.\n\nStatus Exception options\n\nstatusexception = true, throw HTTP.StatusError for response status >= 300.\n\nSSLContext options\n\nrequire_ssl_verification = false, pass MBEDTLS_SSL_VERIFY_REQUIRED to the mbed TLS library. \"... peer must present a valid certificate, handshake is aborted if   verification failed.\"\nsslconfig = SSLConfig(require_ssl_verification)\n\nBasic Authenticaiton options\n\nbasicauthorization=false, add Authorization: Basic header using credentials from url userinfo.\n\nAWS Authenticaiton options\n\nawsauthorization = false, enable AWS4 Authentication.\naws_service = split(url.host, \".\")[1]\naws_region = split(url.host, \".\")[2]\naws_access_key_id = ENV[\"AWS_ACCESS_KEY_ID\"]\naws_secret_access_key = ENV[\"AWS_SECRET_ACCESS_KEY\"]\naws_session_token = get(ENV, \"AWS_SESSION_TOKEN\", \"\")\nbody_sha256 = digest(MD_SHA256, body),\nbody_md5 = digest(MD_MD5, body),\n\nCookie options\n\ncookies = false, enable cookies.\ncookiejar::Dict{String, Set{Cookie}}=default_cookiejar\n\nCananoincalization options\n\ncanonicalizeheaders = false, rewrite request and response headers in Canonical-Camel-Dash-Format.\n\nRequest Body Examples\n\nString body:\n\nHTTP.request(\"POST\", \"http://httpbin.org/post\", [], \"post body data\")\n\nStream body from file:\n\nio = open(\"post_data.txt\", \"r\")\nHTTP.request(\"POST\", \"http://httpbin.org/post\", [], io)\n\nGenerator body:\n\nchunks = (\"chunk$i\" for i in 1:1000)\nHTTP.request(\"POST\", \"http://httpbin.org/post\", [], chunks)\n\nCollection body:\n\nchunks = [preamble_chunk, data_chunk, checksum(data_chunk)]\nHTTP.request(\"POST\", \"http://httpbin.org/post\", [], chunks)\n\nopen() do io body:\n\nHTTP.open(\"POST\", \"http://httpbin.org/post\") do io\n    write(io, preamble_chunk)\n    write(io, data_chunk)\n    write(io, checksum(data_chunk))\nend\n\nResponse Body Examples\n\nString body:\n\nr = HTTP.request(\"GET\", \"http://httpbin.org/get\")\nprintln(String(r.body))\n\nStream body to file:\n\nio = open(\"get_data.txt\", \"w\")\nr = HTTP.request(\"GET\", \"http://httpbin.org/get\", response_stream=io)\nclose(io)\nprintln(read(\"get_data.txt\"))\n\nStream body through buffer:\n\nio = BufferStream()\n@async while !eof(io)\n    bytes = readavailable(io))\n    println(\"GET data: $bytes\")\nend\nr = HTTP.request(\"GET\", \"http://httpbin.org/get\", response_stream=io)\nclose(io)\n\nStream body through open() do io:\n\nr = HTTP.open(\"GET\", \"http://httpbin.org/stream/10\") do io\n   while !eof(io)\n       println(String(readavailable(io)))\n   end\nend\n\nusing HTTP.IOExtras\n\nHTTP.open(\"GET\", \"https://tinyurl.com/bach-cello-suite-1-ogg\") do http\n    n = 0\n    r = startread(http)\n    l = parse(Int, header(r, \"Content-Length\"))\n    open(`vlc -q --play-and-exit --intf dummy -`, \"w\") do vlc\n        while !eof(http)\n            bytes = readavailable(http)\n            write(vlc, bytes)\n            n += length(bytes)\n            println(\"streamed $n-bytes $((100*n)÷l)%\\u1b[1A\")\n        end\n    end\nend\n\nRequest and Response Body Examples\n\nString bodies:\n\nr = HTTP.request(\"POST\", \"http://httpbin.org/post\", [], \"post body data\")\nprintln(String(r.body))\n\nStream bodies from and to files:\n\nin = open(\"foo.png\", \"r\")\nout = open(\"foo.jpg\", \"w\")\nHTTP.request(\"POST\", \"http://convert.com/png2jpg\", [], in, response_stream=out)\n\nStream bodies through: open() do io:\n\nusing HTTP.IOExtras\n\nHTTP.open(\"POST\", \"http://music.com/play\") do io\n    write(io, JSON.json([\n        \"auth\" => \"12345XXXX\",\n        \"song_id\" => 7,\n    ]))\n    r = startread(io)\n    @show r.status\n    while !eof(io)\n        bytes = readavailable(io))\n        play_audio(bytes)\n    end\nend\n\n\n\n"
},

{
    "location": "index.html#HTTP.open",
    "page": "Home",
    "title": "HTTP.open",
    "category": "Function",
    "text": "HTTP.open(method, url, [,headers]) do io\n    write(io, body)\n    [startread(io) -> HTTP.Response]\n    while !eof(io)\n        readavailable(io) -> AbstractVector{UInt8}\n    end\nend -> HTTP.Response\n\nThe HTTP.open API allows the Request Body to be written to (and/or the Response Body to be read from) an IO stream.\n\ne.g. Streaming an audio file to the vlc player:\n\nHTTP.open(\"GET\", \"https://tinyurl.com/bach-cello-suite-1-ogg\") do http\n    open(`vlc -q --play-and-exit --intf dummy -`, \"w\") do vlc\n        write(vlc, http)\n    end\nend\n\n\n\n"
},

{
    "location": "index.html#HTTP.get",
    "page": "Home",
    "title": "HTTP.get",
    "category": "Function",
    "text": "HTTP.get(url [, headers]; <keyword arguments>) -> HTTP.Response\n\nShorthand for HTTP.request(\"GET\", ...). See HTTP.request.\n\n\n\n"
},

{
    "location": "index.html#HTTP.put",
    "page": "Home",
    "title": "HTTP.put",
    "category": "Function",
    "text": "HTTP.put(url, headers, body; <keyword arguments>) -> HTTP.Response\n\nShorthand for HTTP.request(\"PUT\", ...). See HTTP.request.\n\n\n\n"
},

{
    "location": "index.html#HTTP.post",
    "page": "Home",
    "title": "HTTP.post",
    "category": "Function",
    "text": "HTTP.post(url, headers, body; <keyword arguments>) -> HTTP.Response\n\nShorthand for HTTP.request(\"POST\", ...). See HTTP.request.\n\n\n\n"
},

{
    "location": "index.html#HTTP.head",
    "page": "Home",
    "title": "HTTP.head",
    "category": "Function",
    "text": "HTTP.head(url; <keyword arguments>) -> HTTP.Response\n\nShorthand for HTTP.request(\"HEAD\", ...). See HTTP.request.\n\n\n\n"
},

{
    "location": "index.html#HTTP.ExceptionRequest.StatusError",
    "page": "Home",
    "title": "HTTP.ExceptionRequest.StatusError",
    "category": "Type",
    "text": "The Response has a 4xx, 5xx or unrecognised status code.\n\nFields:\n\nstatus::Int16, the response status code.\nresponse the HTTP.Response\n\n\n\n"
},

{
    "location": "index.html#HTTP.Parsers.ParsingError",
    "page": "Home",
    "title": "HTTP.Parsers.ParsingError",
    "category": "Type",
    "text": "The [Parser] input was invalid.\n\nFields:\n\ncode, internal error code\nstate, internal parsing state.\nstatus::Int, HTTP response status.\nmsg::String, error message.\n\n\n\n"
},

{
    "location": "index.html#HTTP.IOExtras.IOError",
    "page": "Home",
    "title": "HTTP.IOExtras.IOError",
    "category": "Type",
    "text": "The request terminated with due to an IO-related error.\n\nFields:\n\ne, the error.\n\n\n\n"
},

{
    "location": "index.html#Requests-1",
    "page": "Home",
    "title": "Requests",
    "category": "section",
    "text": "HTTP.request(::String,::HTTP.URIs.URI,::Array{Pair{String,String},1},::Any)\nHTTP.open\nHTTP.get\nHTTP.put\nHTTP.post\nHTTP.headRequest functions may throw the following exceptions:HTTP.StatusError\nHTTP.ParsingError\nHTTP.IOErrorBase.DNSError"
},

{
    "location": "index.html#HTTP.Servers.listen",
    "page": "Home",
    "title": "HTTP.Servers.listen",
    "category": "Function",
    "text": "HTTP.listen([host=\"localhost\" [, port=8081]]; <keyword arguments>) do http\n    ...\nend\n\nListen for HTTP connections and execute the do function for each request.\n\nOptional keyword arguments:\n\nssl::Bool = false, use https.\nrequire_ssl_verification = true, pass MBEDTLS_SSL_VERIFY_REQUIRED to the mbed TLS library. \"... peer must present a valid certificate, handshake is aborted if   verification failed.\"\nsslconfig = SSLConfig(require_ssl_verification)\npipeline_limit = 16, number of concurrent requests per connection.\nreuse_limit = nolimit, number of times a connection is allowed to be reused                          after the first request.\ntcpisvalid::Function (::TCPSocket) -> Bool, check accepted connection before  processing requests. e.g. to implement source IP filtering, rate-limiting,  etc.\ntcpref::Ref{Base.TCPServer}, this reference is set to the underlying                                TCPServer. e.g. to allow closing the server.\n\ne.g.\n\n    HTTP.listen() do http::HTTP.Stream\n        @show http.message\n        @show HTTP.header(http, \"Content-Type\")\n        while !eof(http)\n            println(\"body data: \", String(readavailable(http)))\n        end\n        setstatus(http, 404)\n        setheader(http, \"Foo-Header\" => \"bar\")\n        startwrite(http)\n        write(http, \"response body\")\n        write(http, \"more response body\")\n    end\n\n    HTTP.listen() do request::HTTP.Request\n        @show HTTP.header(request, \"Content-Type\")\n        @show HTTP.payload(request)\n        return HTTP.Response(404)\n    end\n\n\n\n"
},

{
    "location": "index.html#HTTP.Servers.serve",
    "page": "Home",
    "title": "HTTP.Servers.serve",
    "category": "Function",
    "text": "HTTP.serve([server,] host::IPAddr, port::Int; verbose::Bool=true, kwargs...)\n\nStart a server listening on the provided host and port. verbose indicates whether server activity should be logged. Optional keyword arguments allow construction of Server on the fly if the server argument isn't provided directly. See ?HTTP.Server for more details on server construction and supported keyword arguments. By default, HTTP.serve aims to \"never die\", catching and recovering from all internal errors. Two methods for stopping HTTP.serve include interrupting (ctrl/cmd+c) if blocking on the main task, or sending the kill signal via the server's in channel (put!(server.in, HTTP.Servers.KILL)).\n\n\n\n"
},

{
    "location": "index.html#HTTP.Servers.Server",
    "page": "Home",
    "title": "HTTP.Servers.Server",
    "category": "Type",
    "text": "Server(handler, logger::IO=STDOUT; kwargs...)\n\nAn http/https server. Supports listening on a host and port via the HTTP.serve(server, host, port) function. handler is a function of the form f(::Request, ::Response) -> HTTP.Response, i.e. it takes both a Request and pre-built Response objects as inputs and returns the, potentially modified, Response. logger indicates where logging output should be directed. When HTTP.serve is called, it aims to \"never die\", catching and recovering from all internal errors. To forcefully stop, one can obviously kill the julia process, interrupt (ctrl/cmd+c) if main task, or send the kill signal over a server in channel like: put!(server.in, HTTP.Servers.KILL).\n\nSupported keyword arguments include:\n\ncert: if https, the cert file to use, as passed to HTTP.MbedTLS.SSLConfig(cert, key)\nkey: if https, the key file to use, as passed to HTTP.MbedTLS.SSLConfig(cert, key)\ntlsconfig: pass in an already-constructed HTTP.MbedTLS.SSLConfig instance\nreadtimeout: how long a client connection will be left open without receiving any bytes\nratelimit: a Rational{Int} of the form 5//1 indicating how many messages//second should be allowed per client IP address; requests exceeding the rate limit will be dropped\nsupport100continue: a Bool indicating whether Expect: 100-continue headers should be supported for delayed request body sending; default = true\nlogbody: whether the Response body should be logged when verbose=true logging is enabled; default = true\n\n\n\n"
},

{
    "location": "index.html#HTTP.Handlers.Handler",
    "page": "Home",
    "title": "HTTP.Handlers.Handler",
    "category": "Type",
    "text": "Abstract type representing an object that knows how to \"handle\" a server request.\n\nTypes of handlers include HandlerFunction (a julia function of the form f(request) and Router (which pattern matches request url paths to other specific Handler types).\n\n\n\n"
},

{
    "location": "index.html#HTTP.Handlers.HandlerFunction",
    "page": "Home",
    "title": "HTTP.Handlers.HandlerFunction",
    "category": "Type",
    "text": "HandlerFunction(f::Function)\n\nA Function-wrapper type that is a subtype of Handler. Takes a single Function as an argument. The provided argument should be of the form f(request) => Response, i.e. it accepts a Request returns a Response.\n\n\n\n"
},

{
    "location": "index.html#HTTP.Handlers.Router",
    "page": "Home",
    "title": "HTTP.Handlers.Router",
    "category": "Type",
    "text": "Router(h::Handler) Router(f::Function) Router()\n\nAn HTTP.Handler type that supports mapping request url paths to other HTTP.Handler types. Can accept a default Handler or Function that will be used in case no other handlers match; by default, a 404 response handler is used. Paths can be mapped to a handler via HTTP.register!(r::Router, path, handler), see ?HTTP.register! for more details.\n\n\n\n"
},

{
    "location": "index.html#HTTP.Handlers.register!",
    "page": "Home",
    "title": "HTTP.Handlers.register!",
    "category": "Function",
    "text": "HTTP.register!(r::Router, url, handler) HTTP.register!(r::Router, m::String, url, handler)\n\nFunction to map request urls matching url and an optional method m to another handler::HTTP.Handler. URLs are registered one at a time, and multiple urls can map to the same handler. The URL can be passed as a String or HTTP.URI object directly. Requests can be routed based on: method, scheme, hostname, or path. The following examples show how various urls will direct how a request is routed by a server:\n\n\"http://*\": match all HTTP requests, regardless of path\n\"https://*\": match all HTTPS requests, regardless of path\n\"google\": regardless of scheme, match requests to the hostname \"google\"\n\"google/gmail\": match requests to hostname \"google\", and path starting with \"gmail\"\n\"/gmail\": regardless of scheme or host, match any request with a path starting with \"gmail\"\n\"/gmail/userId/*/inbox: match any request matching the path pattern, \"*\" is used as a wildcard that matches any value between the two \"/\"\n\n\n\n"
},

{
    "location": "index.html#Server-/-Handlers-1",
    "page": "Home",
    "title": "Server / Handlers",
    "category": "section",
    "text": "HTTP.listen\nHTTP.Servers.serve\nHTTP.Servers.Server\nHTTP.Handler\nHTTP.HandlerFunction\nHTTP.Router\nHTTP.register!"
},

{
    "location": "index.html#HTTP.URIs.URI",
    "page": "Home",
    "title": "HTTP.URIs.URI",
    "category": "Type",
    "text": "HTTP.URI(; scheme=\"\", host=\"\", port=\"\", etc...)\nHTTP.URI(str) = parse(HTTP.URI, str::String)\n\nA type representing a valid uri. Can be constructed from distinct parts using the various supported keyword arguments. With a raw, already-encoded uri string, use parse(HTTP.URI, str) to parse the HTTP.URI directly. The HTTP.URI constructors will automatically escape any provided query arguments, typically provided as \"key\"=>\"value\"::Pair or Dict(\"key\"=>\"value\"). Note that multiple values for a single query key can provided like Dict(\"key\"=>[\"value1\", \"value2\"]).\n\nThe URI struct stores the compelte URI in the uri::String field and the component parts in the following SubString fields:\n\nscheme, e.g. \"http\" or \"https\"\nuserinfo, e.g. \"username:password\"\nhost e.g. \"julialang.org\"\nport e.g. \"80\" or \"\"\npath e.g \"/\"\nquery e.g. \"Foo=1&Bar=2\"\nfragment\n\nThe HTTP.resource(::URI) function returns a target-resource string for the URI RFC7230 5.3. e.g. \"$path?$query#$fragment\".\n\nThe HTTP.queryparams(::URI) function returns a Dict containing the query.\n\n\n\n"
},

{
    "location": "index.html#HTTP.URIs.escapeuri",
    "page": "Home",
    "title": "HTTP.URIs.escapeuri",
    "category": "Function",
    "text": "percent-encode a string, dict, or pair for a uri\n\n\n\n"
},

{
    "location": "index.html#HTTP.URIs.unescapeuri",
    "page": "Home",
    "title": "HTTP.URIs.unescapeuri",
    "category": "Function",
    "text": "unescape a percent-encoded uri/url\n\n\n\n"
},

{
    "location": "index.html#HTTP.URIs.splitpath",
    "page": "Home",
    "title": "HTTP.URIs.splitpath",
    "category": "Function",
    "text": "Splits the path into components See: http://tools.ietf.org/html/rfc3986#section-3.3\n\n\n\n"
},

{
    "location": "index.html#Base.isvalid-Tuple{HTTP.URIs.URI}",
    "page": "Home",
    "title": "Base.isvalid",
    "category": "Method",
    "text": "checks if a HTTP.URI is valid\n\n\n\n"
},

{
    "location": "index.html#URIs-1",
    "page": "Home",
    "title": "URIs",
    "category": "section",
    "text": "HTTP.URI\nHTTP.URIs.escapeuri\nHTTP.URIs.unescapeuri\nHTTP.URIs.splitpath\nBase.isvalid(::HTTP.URIs.URI)"
},

{
    "location": "index.html#HTTP.Cookies.Cookie",
    "page": "Home",
    "title": "HTTP.Cookies.Cookie",
    "category": "Type",
    "text": "Cookie()\nCookie(; kwargs...)\nCookie(name, value; kwargs...)\n\nA Cookie represents an HTTP cookie as sent in the Set-Cookie header of an HTTP response or the Cookie header of an HTTP request. Supported fields (which can be set using keyword arguments) include:\n\nname: name of the cookie\nvalue: value of the cookie\npath: applicable path for the cookie\ndomain: applicable domain for the cookie\nexpires: a Dates.DateTime representing when the cookie should expire\nmaxage: maxage == 0 means no max age, maxage < 0 means delete cookie now, max age > 0 means the # of seconds until expiration\nsecure::Bool: secure cookie attribute\nhttponly::Bool: httponly cookie attribute\nhostonly::Bool: hostonly cookie attribute\n\nSee http:#tools.ietf.org/html/rfc6265 for details.\n\n\n\n"
},

{
    "location": "index.html#Cookies-1",
    "page": "Home",
    "title": "Cookies",
    "category": "section",
    "text": "HTTP.Cookie"
},

{
    "location": "index.html#HTTP.sniff",
    "page": "Home",
    "title": "HTTP.sniff",
    "category": "Function",
    "text": "HTTP.sniff(content::Union{Vector{UInt8}, String, IO}) => String (mimetype)\n\nHTTP.sniff will look at the first 512 bytes of content to try and determine a valid mimetype. If a mimetype can't be determined appropriately, \"application/octet-stream\" is returned.\n\nSupports JSON detection through the HTTP.isjson(content) function.\n\n\n\n"
},

{
    "location": "index.html#HTTP.Strings.escapehtml",
    "page": "Home",
    "title": "HTTP.Strings.escapehtml",
    "category": "Function",
    "text": "escapeHTML(i::String)\n\nReturns a string with special HTML characters escaped: &, <, >, \", '\n\n\n\n"
},

{
    "location": "index.html#Utilities-1",
    "page": "Home",
    "title": "Utilities",
    "category": "section",
    "text": "HTTP.sniff\nHTTP.Strings.escapehtml"
},

{
    "location": "index.html#HTTP.Layer",
    "page": "Home",
    "title": "HTTP.Layer",
    "category": "Type",
    "text": "Request Execution Stack\n\nThe Request Execution Stack is separated into composable layers.\n\nEach layer is defined by a nested type Layer{Next} where the Next parameter defines the next layer in the stack. The request method for each layer takes a Layer{Next} type as its first argument and dispatches the request to the next layer using request(Next, ...).\n\nThe example below defines three layers and three stacks each with a different combination of layers.\n\nabstract type Layer end\nabstract type Layer1{Next <: Layer} <: Layer end\nabstract type Layer2{Next <: Layer} <: Layer end\nabstract type Layer3 <: Layer end\n\nrequest(::Type{Layer1{Next}}, data) where Next = \"L1\", request(Next, data)\nrequest(::Type{Layer2{Next}}, data) where Next = \"L2\", request(Next, data)\nrequest(::Type{Layer3}, data) = \"L3\", data\n\nconst stack1 = Layer1{Layer2{Layer3}}\nconst stack2 = Layer2{Layer1{Layer3}}\nconst stack3 = Layer1{Layer3}\n\njulia> request(stack1, \"foo\")\n(\"L1\", (\"L2\", (\"L3\", \"foo\")))\n\njulia> request(stack2, \"bar\")\n(\"L2\", (\"L1\", (\"L3\", \"bar\")))\n\njulia> request(stack3, \"boo\")\n(\"L1\", (\"L3\", \"boo\"))\n\nThis stack definition pattern gives the user flexibility in how layers are combined but still allows Julia to do whole-stack comiple time optimistations.\n\ne.g. the request(stack1, \"foo\") call above is optimised down to a single function:\n\njulia> code_typed(request, (Type{stack1}, String))[1].first\nCodeInfo(:(begin\n    return (Core.tuple)(\"L1\", (Core.tuple)(\"L2\", (Core.tuple)(\"L3\", data)))\nend))\n\n\n\n"
},

{
    "location": "index.html#HTTP.stack",
    "page": "Home",
    "title": "HTTP.stack",
    "category": "Function",
    "text": "The stack() function returns the default HTTP Layer-stack type. This type is passed as the first parameter to the HTTP.request function.\n\nstack() accepts optional keyword arguments to enable/disable specific layers in the stack: request(method, args...; kw...) request(stack(;kw...), args...; kw...)\n\nThe minimal request execution stack is:\n\nstack = MessageLayer{ConnectionPoolLayer{StreamLayer}}\n\nThe figure below illustrates the full request exection stack and its relationship with HTTP.Response, HTTP.Parser, HTTP.Stream and the HTTP.ConnectionPool.\n\n ┌────────────────────────────────────────────────────────────────────────────┐\n │                                            ┌───────────────────┐           │\n │  HTTP.jl Request Execution Stack           │ HTTP.ParsingError ├ ─ ─ ─ ─ ┐ │\n │                                            └───────────────────┘           │\n │                                            ┌───────────────────┐         │ │\n │                                            │ HTTP.IOError      ├ ─ ─ ─     │\n │                                            └───────────────────┘      │  │ │\n │                                            ┌───────────────────┐           │\n │                                            │ HTTP.StatusError  │─ ─   │  │ │\n │                                            └───────────────────┘   │       │\n │                                            ┌───────────────────┐      │  │ │\n │     request(method, url, headers, body) -> │ HTTP.Response     │   │       │\n │             ──────────────────────────     └─────────▲─────────┘      │  │ │\n │                           ║                          ║             │       │\n │   ┌────────────────────────────────────────────────────────────┐      │  │ │\n │   │ request(RedirectLayer,     method, ::URI, ::Headers, body) │   │       │\n │   ├────────────────────────────────────────────────────────────┤      │  │ │\n │   │ request(BasicAuthLayer,    method, ::URI, ::Headers, body) │   │       │\n │   ├────────────────────────────────────────────────────────────┤      │  │ │\n │   │ request(CookieLayer,       method, ::URI, ::Headers, body) │   │       │\n │   ├────────────────────────────────────────────────────────────┤      │  │ │\n │   │ request(CanonicalizeLayer, method, ::URI, ::Headers, body) │   │       │\n │   ├────────────────────────────────────────────────────────────┤      │  │ │\n │   │ request(MessageLayer,      method, ::URI, ::Headers, body) │   │       │\n │   ├────────────────────────────────────────────────────────────┤      │  │ │\n │   │ request(AWS4AuthLayer,             ::URI, ::Request, body) │   │       │\n │   ├────────────────────────────────────────────────────────────┤      │  │ │\n │   │ request(RetryLayer,                ::URI, ::Request, body) │   │       │\n │   ├────────────────────────────────────────────────────────────┤      │  │ │\n │   │ request(ExceptionLayer,            ::URI, ::Request, body) ├ ─ ┘       │\n │   ├────────────────────────────────────────────────────────────┤      │  │ │\n┌┼───┤ request(ConnectionPoolLayer,       ::URI, ::Request, body) ├ ─ ─ ─     │\n││   ├────────────────────────────────────────────────────────────┤         │ │\n││   │ request(TimeoutLayer,              ::IO,  ::Request, body) │           │\n││   ├────────────────────────────────────────────────────────────┤         │ │\n││   │ request(StreamLayer,               ::IO,  ::Request, body) │           │\n││   └──────────────┬───────────────────┬─────────────────────────┘         │ │\n│└──────────────────┼────────║──────────┼───────────────║─────────────────────┘\n│                   │        ║          │               ║                   │  \n│┌──────────────────▼───────────────┐   │  ┌──────────────────────────────────┐\n││ HTTP.Request                     │   │  │ HTTP.Response                  │ │\n││                                  │   │  │                                  │\n││ method::String                   ◀───┼──▶ status::Int                    │ │\n││ target::String                   │   │  │ headers::Vector{Pair}            │\n││ headers::Vector{Pair}            │   │  │ body::Vector{UInt8}            │ │\n││ body::Vector{UInt8}              │   │  │                                  │\n│└──────────────────▲───────────────┘   │  └───────────────▲────────────────┼─┘\n│┌──────────────────┴────────║──────────▼───────────────║──┴──────────────────┐\n││ HTTP.Stream <:IO          ║           ╔══════╗       ║                   │ │\n││   ┌───────────────────────────┐       ║   ┌──▼─────────────────────────┐   │\n││   │ startwrite(::Stream)      │       ║   │ startread(::Stream)        │ │ │\n││   │ write(::Stream, body)     │       ║   │ read(::Stream) -> body     │   │\n││   │ ...                       │       ║   │ ...                        │ │ │\n││   │ closewrite(::Stream)      │       ║   │ closeread(::Stream)        │   │\n││   └───────────────────────────┘       ║   └────────────────────────────┘ │ │\n│└───────────────────────────║────────┬──║──────║───────║──┬──────────────────┘\n│┌──────────────────────────────────┐ │  ║ ┌────▼───────║──▼────────────────┴─┐\n││ HTTP.Messages                    │ │  ║ │ HTTP.Parser                      │\n││                                  │ │  ║ │                                  │\n││ writestartline(::IO, ::Request)  │ │  ║ │ parseheaders(bytes) do h::Pair   │\n││ writeheaders(::IO, ::Request)    │ │  ║ │ parsebody(bytes) -> bytes        │\n│└──────────────────────────────────┘ │  ║ └──────────────────────────────────┘\n│                            ║        │  ║                                     \n│┌───────────────────────────║────────┼──║────────────────────────────────────┐\n└▶ HTTP.ConnectionPool       ║        │  ║                                    │\n │                     ┌──────────────▼────────┐ ┌───────────────────────┐    │\n │ getconnection() ->  │ HTTP.Transaction <:IO │ │ HTTP.Transaction <:IO │    │\n │                     └───────────────────────┘ └───────────────────────┘    │\n │                           ║    ╲│╱    ║                  ╲│╱               │\n │                           ║     │     ║                   │                │\n │                     ┌───────────▼───────────┐ ┌───────────▼───────────┐    │\n │              pool: [│ HTTP.Connection       │,│ HTTP.Connection       │...]│\n │                     └───────────┬───────────┘ └───────────┬───────────┘    │\n │                           ║     │     ║                   │                │\n │                     ┌───────────▼───────────┐ ┌───────────▼───────────┐    │\n │                     │ Base.TCPSocket <:IO   │ │MbedTLS.SSLContext <:IO│    │\n │                     └───────────────────────┘ └───────────┬───────────┘    │\n │                           ║           ║                   │                │\n │                           ║           ║       ┌───────────▼───────────┐    │\n │                           ║           ║       │ Base.TCPSocket <:IO   │    │\n │                           ║           ║       └───────────────────────┘    │\n └───────────────────────────║───────────║────────────────────────────────────┘\n                             ║           ║                                     \n ┌───────────────────────────║───────────║──────────────┐  ┏━━━━━━━━━━━━━━━━━━┓\n │ HTTP Server               ▼                          │  ┃ data flow: ════▶ ┃\n │                        Request     Response          │  ┃ reference: ────▶ ┃\n └──────────────────────────────────────────────────────┘  ┗━━━━━━━━━━━━━━━━━━┛\n\nSee docs/src/layers.monopic.\n\n\n\n"
},

{
    "location": "index.html#HTTP.jl-Internal-Architecture-1",
    "page": "Home",
    "title": "HTTP.jl Internal Architecture",
    "category": "section",
    "text": "HTTP.Layer\nHTTP.stack"
},

{
    "location": "index.html#HTTP.RedirectRequest.RedirectLayer",
    "page": "Home",
    "title": "HTTP.RedirectRequest.RedirectLayer",
    "category": "Type",
    "text": "request(RedirectLayer, method, ::URI, headers, body) -> HTTP.Response\n\nRedirects the request in the case of 3xx response status.\n\n\n\n"
},

{
    "location": "index.html#HTTP.BasicAuthRequest.BasicAuthLayer",
    "page": "Home",
    "title": "HTTP.BasicAuthRequest.BasicAuthLayer",
    "category": "Type",
    "text": "request(BasicAuthLayer, method, ::URI, headers, body) -> HTTP.Response\n\nAdd Authorization: Basic header using credentials from url userinfo.\n\n\n\n"
},

{
    "location": "index.html#HTTP.CookieRequest.CookieLayer",
    "page": "Home",
    "title": "HTTP.CookieRequest.CookieLayer",
    "category": "Type",
    "text": "request(CookieLayer, method, ::URI, headers, body) -> HTTP.Response\n\nAdd locally stored Cookies to the request headers. Store new Cookies found in the response headers.\n\n\n\n"
},

{
    "location": "index.html#HTTP.CanonicalizeRequest.CanonicalizeLayer",
    "page": "Home",
    "title": "HTTP.CanonicalizeRequest.CanonicalizeLayer",
    "category": "Type",
    "text": "request(CanonicalizeLayer, method, ::URI, headers, body) -> HTTP.Response\n\nRewrite request and response headers in Canonical-Camel-Dash-Format.\n\n\n\n"
},

{
    "location": "index.html#HTTP.MessageRequest.MessageLayer",
    "page": "Home",
    "title": "HTTP.MessageRequest.MessageLayer",
    "category": "Type",
    "text": "request(MessageLayer, method, ::URI, headers, body) -> HTTP.Response\n\nConstruct a Request object and set mandatory headers.\n\n\n\n"
},

{
    "location": "index.html#HTTP.AWS4AuthRequest.AWS4AuthLayer",
    "page": "Home",
    "title": "HTTP.AWS4AuthRequest.AWS4AuthLayer",
    "category": "Type",
    "text": "request(AWS4AuthLayer, ::URI, ::Request, body) -> HTTP.Response\n\nAdd a AWS Signature Version 4 Authorization header to a Request.\n\nCredentials are read from environment variables AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and AWS_SESSION_TOKEN.\n\n\n\n"
},

{
    "location": "index.html#HTTP.RetryRequest.RetryLayer",
    "page": "Home",
    "title": "HTTP.RetryRequest.RetryLayer",
    "category": "Type",
    "text": "request(RetryLayer, ::URI, ::Request, body) -> HTTP.Response\n\nRetry the request if it throws a recoverable exception.\n\nBase.retry and Base.ExponentialBackOff implement a randomised exponentially increasing delay is introduced between attempts to avoid exacerbating network congestion.\n\nMethods of isrecoverable(e) define which exception types lead to a retry. e.g. HTTP.IOError, Base.DNSError, Base.EOFError and HTTP.StatusError (if status is `5xx).\n\n\n\n"
},

{
    "location": "index.html#HTTP.ExceptionRequest.ExceptionLayer",
    "page": "Home",
    "title": "HTTP.ExceptionRequest.ExceptionLayer",
    "category": "Type",
    "text": "request(ExceptionLayer, ::URI, ::Request, body) -> HTTP.Response\n\nThrow a StatusError if the request returns an error response status.\n\n\n\n"
},

{
    "location": "index.html#HTTP.ConnectionRequest.ConnectionPoolLayer",
    "page": "Home",
    "title": "HTTP.ConnectionRequest.ConnectionPoolLayer",
    "category": "Type",
    "text": "request(ConnectionPoolLayer, ::URI, ::Request, body) -> HTTP.Response\n\nRetrieve an IO connection from the ConnectionPool.\n\nClose the connection if the request throws an exception. Otherwise leave it open so that it can be reused.\n\nIO related exceptions from Base are wrapped in HTTP.IOError. See isioerror.\n\n\n\n"
},

{
    "location": "index.html#HTTP.TimeoutRequest.TimeoutLayer",
    "page": "Home",
    "title": "HTTP.TimeoutRequest.TimeoutLayer",
    "category": "Type",
    "text": "request(TimeoutLayer, ::IO, ::Request, body) -> HTTP.Response\n\nClose IO if no data has been received for timeout seconds.\n\n\n\n"
},

{
    "location": "index.html#HTTP.StreamRequest.StreamLayer",
    "page": "Home",
    "title": "HTTP.StreamRequest.StreamLayer",
    "category": "Type",
    "text": "request(StreamLayer, ::IO, ::Request, body) -> HTTP.Response\n\nCreate a Stream to send a Request and body to an IO stream and read the response.\n\nSens the Request body in a background task and begins reading the response immediately so that the transmission can be aborted if the Response status indicates that the server does not wish to receive the message body. RFC7230 6.5.\n\n\n\n"
},

{
    "location": "index.html#Request-Execution-Layers-1",
    "page": "Home",
    "title": "Request Execution Layers",
    "category": "section",
    "text": "HTTP.RedirectLayer\nHTTP.BasicAuthLayer\nHTTP.CookieLayer\nHTTP.CanonicalizeLayer\nHTTP.MessageLayer\nHTTP.AWS4AuthLayer\nHTTP.RetryLayer\nHTTP.ExceptionLayer\nHTTP.ConnectionPoolLayer\nHTTP.TimeoutLayer\nHTTP.StreamLayer"
},

{
    "location": "index.html#HTTP.Parsers.Parser",
    "page": "Home",
    "title": "HTTP.Parsers.Parser",
    "category": "Type",
    "text": "The parser separates a raw HTTP Message into its component parts.\n\nIf the input data is invalid the Parser throws a ParsingError.\n\nThe parser processes a single HTTP Message. If the input stream contains multiple Messages the Parser stops at the end of the first Message. The parseheaders and parsebody functions return a SubArray containing the unuses portion of the input.\n\nThe Parser does not interpret the Message Headers except as needed to parse the Message Body. It is beyond the scope of the Parser to deal with repeated header fields, multi-line values, cookies or case normalization.\n\nThe Parser has no knowledge of the high-level Request and Response structs defined in Messages.jl. The Parser has it's own low level Message struct that represents both Request and Response Messages.\n\n\n\n"
},

{
    "location": "index.html#Parser-1",
    "page": "Home",
    "title": "Parser",
    "category": "section",
    "text": "Source: Parsers.jlHTTP.Parsers.Parser"
},

{
    "location": "index.html#HTTP.Messages",
    "page": "Home",
    "title": "HTTP.Messages",
    "category": "Module",
    "text": "The Messages module defines structs that represent HTTP.Request and HTTP.Response Messages.\n\nThe Response struct has a request field that points to the corresponding Request; and the Request struct has a response field. The Request struct also has a parent field that points to a Response in the case of HTTP Redirect.\n\nThe Messages module defines IO read and write methods for Messages but it does not deal with URIs, creating connections, or executing requests.\n\nThe read methods throw EOFError exceptions if input data is incomplete. and call parser functions that may throw HTTP.ParsingError exceptions. The read and write methods may also result in low level IO exceptions.\n\nSending Messages\n\nMessages are formatted and written to an IO stream by Base.write(::IO,::HTTP.Messages.Message) and or HTTP.Messages.writeheaders.\n\nReceiving Messages\n\nMessages are parsed from IO stream data by HTTP.Messages.readheaders. This function calls HTTP.Messages.appendheader and HTTP.Messages.readstartline!.\n\nThe read methods rely on HTTP.IOExtras.unread! to push excess data back to the input stream.\n\nHeaders\n\nHeaders are represented by Vector{Pair{String,String}}. As compared to Dict{String,String} this allows repeated header fields and preservation of order.\n\nHeader values can be accessed by name using HTTP.Messages.header and HTTP.Messages.setheader (case-insensitive).\n\nThe HTTP.Messages.appendheader function handles combining multi-line values, repeated header fields and special handling of multiple Set-Cookie headers.\n\nBodies\n\nThe HTTP.Message structs represent the Message Body as Vector{UInt8}.\n\nStreaming of request and response bodies is handled by the HTTP.StreamLayer and the HTTP.Stream <: IO stream.\n\n\n\n"
},

{
    "location": "index.html#Messages-1",
    "page": "Home",
    "title": "Messages",
    "category": "section",
    "text": "Source: Messages.jlHTTP.Messages"
},

{
    "location": "index.html#HTTP.Streams.Stream",
    "page": "Home",
    "title": "HTTP.Streams.Stream",
    "category": "Type",
    "text": "Stream(::IO, ::Request, ::Parser)\n\nCreates a HTTP.Stream that wraps an existing IO stream.\n\nstartwrite(::Stream) sends the Request headers to the IO stream.\nwrite(::Stream, body) sends the body (or a chunk of the body).\nclosewrite(::Stream) sends the final 0 chunk (if needed) and calls closewrite on the IO stream. When the IO stream is a HTTP.ConnectionPool.Transaction, calling closewrite releases the HTTP.ConnectionPool.Connection back into the pool for use by the next pipelined request.\nstartread(::Stream) calls startread on the IO stream then  reads and parses the Response headers.  When the IO stream is a HTTP.ConnectionPool.Transaction, calling startread waits for other pipelined responses to be read from the HTTP.ConnectionPool.Connection.\neof(::Stream) and readavailable(::Stream) parse the body from the IO  stream.\ncloseread(::Stream) reads the trailers and calls closeread on the IO  stream.  When the IO stream is a HTTP.ConnectionPool.Transaction,  calling closeread releases the readlock and allows the next pipelined  response to be read by another Stream that is waiting in startread.  If the Parser has not recieved a complete response, closeread throws  an EOFError.\n\n\n\n"
},

{
    "location": "index.html#Streams-1",
    "page": "Home",
    "title": "Streams",
    "category": "section",
    "text": "Source: Streams.jlHTTP.Streams.Stream"
},

{
    "location": "index.html#HTTP.ConnectionPool",
    "page": "Home",
    "title": "HTTP.ConnectionPool",
    "category": "Module",
    "text": "This module provides the getconnection function with support for:\n\nOpening TCP and SSL connections.\nReusing connections for multiple Request/Response Messages,\nPipelining Request/Response Messages. i.e. allowing a new Request to be sent before previous Responses have been read.\n\nThis module defines a Connection struct to manage pipelining and connection reuse and a Transaction<: IO struct to manage a single pipelined request. Methods are provided for eof, readavailable, unsafe_write and close. This allows the Transaction object to act as a proxy for the TCPSocket or SSLContext that it wraps.\n\nThe pool is a collection of open Connections.  The request function calls getconnection to retrieve a connection from the pool.  When the request function has written a Request Message it calls closewrite to signal that the Connection can be reused for writing (to send the next Request). When the request function has read the Response Message it calls closeread to signal that the Connection can be reused for reading.\n\n\n\n"
},

{
    "location": "index.html#Connections-1",
    "page": "Home",
    "title": "Connections",
    "category": "section",
    "text": "Source: ConnectionPool.jlHTTP.ConnectionPool"
},

{
    "location": "index.html#Internal-Interfaces-1",
    "page": "Home",
    "title": "Internal Interfaces",
    "category": "section",
    "text": ""
},

{
    "location": "index.html#HTTP.Parsers.Message",
    "page": "Home",
    "title": "HTTP.Parsers.Message",
    "category": "Type",
    "text": "method::String: the HTTP method RFC7230 3.1.1\nmajor and minor: HTTP version RFC7230 2.6\ntarget::String: request target RFC7230 5.3\nstatus::Int: response status RFC7230 3.1.2\n\n\n\n"
},

{
    "location": "index.html#HTTP.Parsers.parseheaders",
    "page": "Home",
    "title": "HTTP.Parsers.parseheaders",
    "category": "Function",
    "text": "parseheaders(::Parser, bytes) do h::Pair{String,String} ... -> excess\n\nRead headers from bytes, passing each field/value pair to f. Returns a SubArray containing bytes not parsed.\n\ne.g.\n\nexcess = parseheaders(p, bytes) do (k,v)\n    println(\"$k: $v\")\nend\n\n\n\n"
},

{
    "location": "index.html#HTTP.Parsers.parsebody",
    "page": "Home",
    "title": "HTTP.Parsers.parsebody",
    "category": "Function",
    "text": "parsebody(::Parser, bytes) -> data, excess\n\nParse body data from bytes. Returns decoded data and excess bytes not parsed.\n\n\n\n"
},

{
    "location": "index.html#HTTP.Parsers.reset!",
    "page": "Home",
    "title": "HTTP.Parsers.reset!",
    "category": "Function",
    "text": "reset!(::Parser)\n\nRevert Parser to unconfigured state.\n\n\n\n"
},

{
    "location": "index.html#HTTP.Parsers.messagestarted",
    "page": "Home",
    "title": "HTTP.Parsers.messagestarted",
    "category": "Function",
    "text": "messagestarted(::Parser)\n\nHas the Parser begun processng a Message?\n\n\n\n"
},

{
    "location": "index.html#HTTP.Parsers.headerscomplete",
    "page": "Home",
    "title": "HTTP.Parsers.headerscomplete",
    "category": "Function",
    "text": "headerscomplete(::Parser)\n\nHas the Parser processed the entire Message Header?\n\n\n\nheaderscomplete(::Message)\n\nHave the headers been read into this Message?\n\n\n\n"
},

{
    "location": "index.html#HTTP.Parsers.bodycomplete",
    "page": "Home",
    "title": "HTTP.Parsers.bodycomplete",
    "category": "Function",
    "text": "bodycomplete(::Parser)\n\nHas the Parser processed the Message Body?\n\n\n\n"
},

{
    "location": "index.html#HTTP.Parsers.messagecomplete",
    "page": "Home",
    "title": "HTTP.Parsers.messagecomplete",
    "category": "Function",
    "text": "messagecomplete(::Parser)\n\nHas the Parser processed the entire Message?\n\n\n\n"
},

{
    "location": "index.html#HTTP.Parsers.messagehastrailing",
    "page": "Home",
    "title": "HTTP.Parsers.messagehastrailing",
    "category": "Function",
    "text": "messagehastrailing(::Parser)\n\nIs the Parser ready to process trailing headers?\n\n\n\n"
},

{
    "location": "index.html#Parser-Interface-1",
    "page": "Home",
    "title": "Parser Interface",
    "category": "section",
    "text": "HTTP.Parsers.Message\nHTTP.Parsers.parseheaders\nHTTP.Parsers.parsebody\nHTTP.Parsers.reset!\nHTTP.Parsers.messagestarted\nHTTP.Parsers.headerscomplete\nHTTP.Parsers.bodycomplete\nHTTP.Parsers.messagecomplete\nHTTP.Parsers.messagehastrailing"
},

{
    "location": "index.html#HTTP.Messages.Request",
    "page": "Home",
    "title": "HTTP.Messages.Request",
    "category": "Type",
    "text": "Request <: Message\n\nRepresents a HTTP Request Message.\n\nmethod::String  RFC7230 3.1.1\ntarget::String  RFC7230 5.3\nversion::VersionNumber  RFC7230 2.6\nheaders::Vector{Pair{String,String}}  RFC7230 3.2\nbody::Vector{UInt8}  RFC7230 3.3\nresponse, the Response to this Request\nparent, the Response (if any) that led to this request (e.g. in the case of a redirect).  RFC7230 6.4\n\n\n\n"
},

{
    "location": "index.html#HTTP.Messages.Response",
    "page": "Home",
    "title": "HTTP.Messages.Response",
    "category": "Type",
    "text": "Response <: Message\n\nRepresents a HTTP Response Message.\n\nversion::VersionNumber  RFC7230 2.6\nstatus::Int16  RFC7230 3.1.2  RFC7231 6\nheaders::Vector{Pair{String,String}}  RFC7230 3.2\nbody::Vector{UInt8}  RFC7230 3.3\nrequest, the Request that yielded this Response.\n\n\n\n"
},

{
    "location": "index.html#HTTP.Messages.iserror",
    "page": "Home",
    "title": "HTTP.Messages.iserror",
    "category": "Function",
    "text": "iserror(::Response)\n\nDoes this Response have an error status?\n\n\n\n"
},

{
    "location": "index.html#HTTP.Messages.isredirect",
    "page": "Home",
    "title": "HTTP.Messages.isredirect",
    "category": "Function",
    "text": "isredirect(::Response)\n\nDoes this Response have a redirect status?\n\n\n\n"
},

{
    "location": "index.html#HTTP.Messages.ischunked",
    "page": "Home",
    "title": "HTTP.Messages.ischunked",
    "category": "Function",
    "text": "ischunked(::Message)\n\nDoes the Message have a \"Transfer-Encoding: chunked\" header?\n\n\n\n"
},

{
    "location": "index.html#HTTP.Messages.issafe",
    "page": "Home",
    "title": "HTTP.Messages.issafe",
    "category": "Function",
    "text": "issafe(::Request)\n\nhttps://tools.ietf.org/html/rfc7231#section-4.2.1\n\n\n\n"
},

{
    "location": "index.html#HTTP.Messages.isidempotent",
    "page": "Home",
    "title": "HTTP.Messages.isidempotent",
    "category": "Function",
    "text": "isidempotent(::Request)\n\nhttps://tools.ietf.org/html/rfc7231#section-4.2.2\n\n\n\n"
},

{
    "location": "index.html#HTTP.Messages.header",
    "page": "Home",
    "title": "HTTP.Messages.header",
    "category": "Function",
    "text": "header(::Message, key [, default=\"\"]) -> String\n\nGet header value for key (case-insensitive).\n\n\n\n"
},

{
    "location": "index.html#HTTP.Messages.hasheader",
    "page": "Home",
    "title": "HTTP.Messages.hasheader",
    "category": "Function",
    "text": "hasheader(::Message, key) -> Bool\n\nDoes header value for key exist (case-insensitive)?\n\n\n\nhasheader(::Message, key, value) -> Bool\n\nDoes header for key match value (both case-insensitive)?\n\n\n\n"
},

{
    "location": "index.html#HTTP.Messages.setheader",
    "page": "Home",
    "title": "HTTP.Messages.setheader",
    "category": "Function",
    "text": "setheader(::Message, key => value)\n\nSet header value for key (case-insensitive).\n\n\n\n"
},

{
    "location": "index.html#HTTP.Messages.defaultheader",
    "page": "Home",
    "title": "HTTP.Messages.defaultheader",
    "category": "Function",
    "text": "defaultheader(::Message, key => value)\n\nSet header value for key if it is not already set.\n\n\n\n"
},

{
    "location": "index.html#HTTP.Messages.appendheader",
    "page": "Home",
    "title": "HTTP.Messages.appendheader",
    "category": "Function",
    "text": "appendheader(::Message, key => value)\n\nAppend a header value to message.headers.\n\nIf key is \"\" the value is appended to the value of the previous header.\n\nIf key is the same as the previous header, the value is appended to the value of the previous header with a comma delimiter\n\nSet-Cookie headers are not comma-combined because cookies often contain internal commas.\n\n\n\n"
},

{
    "location": "index.html#HTTP.Messages.readheaders",
    "page": "Home",
    "title": "HTTP.Messages.readheaders",
    "category": "Function",
    "text": "readheaders(::IO, ::Parser, ::Message)\n\nRead headers (and startline) from an IO stream into a Message struct. Throw EOFError if input is incomplete.\n\n\n\n"
},

{
    "location": "index.html#HTTP.Messages.readstartline!",
    "page": "Home",
    "title": "HTTP.Messages.readstartline!",
    "category": "Function",
    "text": "readstartline!(::Parsers.Message, ::Message)\n\nRead the start-line metadata from Parser into a ::Message struct.\n\n\n\n"
},

{
    "location": "index.html#HTTP.Parsers.headerscomplete-Tuple{HTTP.Messages.Response}",
    "page": "Home",
    "title": "HTTP.Parsers.headerscomplete",
    "category": "Method",
    "text": "headerscomplete(::Message)\n\nHave the headers been read into this Message?\n\n\n\n"
},

{
    "location": "index.html#HTTP.Messages.readtrailers",
    "page": "Home",
    "title": "HTTP.Messages.readtrailers",
    "category": "Function",
    "text": "readtrailers(::IO, ::Parser, ::Message)\n\nRead trailers from an IO stream into a Message struct.\n\n\n\n"
},

{
    "location": "index.html#HTTP.Messages.writestartline",
    "page": "Home",
    "title": "HTTP.Messages.writestartline",
    "category": "Function",
    "text": "writestartline(::IO, ::Message)\n\ne.g. \"GET /path HTTP/1.1\\r\\n\" or \"HTTP/1.1 200 OK\\r\\n\"\n\n\n\n"
},

{
    "location": "index.html#HTTP.Messages.writeheaders",
    "page": "Home",
    "title": "HTTP.Messages.writeheaders",
    "category": "Function",
    "text": "writeheaders(::IO, ::Message)\n\nWrite Message start line and a line for each \"name: value\" pair and a trailing blank line.\n\n\n\n"
},

{
    "location": "index.html#Base.write-Tuple{IO,HTTP.Messages.Message}",
    "page": "Home",
    "title": "Base.write",
    "category": "Method",
    "text": "write(::IO, ::Message)\n\nWrite start line, headers and body of HTTP Message.\n\n\n\n"
},

{
    "location": "index.html#Messages-Interface-1",
    "page": "Home",
    "title": "Messages Interface",
    "category": "section",
    "text": "HTTP.Messages.Request\nHTTP.Messages.Response\nHTTP.Messages.iserror\nHTTP.Messages.isredirect\nHTTP.Messages.ischunked\nHTTP.Messages.issafe\nHTTP.Messages.isidempotent\nHTTP.Messages.header\nHTTP.Messages.hasheader\nHTTP.Messages.setheader\nHTTP.Messages.defaultheader\nHTTP.Messages.appendheader\nHTTP.Messages.readheaders\nHTTP.Messages.readstartline!\nHTTP.Messages.headerscomplete(::HTTP.Messages.Response)\nHTTP.Messages.readtrailers\nHTTP.Messages.writestartline\nHTTP.Messages.writeheaders\nBase.write(::IO,::HTTP.Messages.Message)"
},

{
    "location": "index.html#HTTP.IOExtras",
    "page": "Home",
    "title": "HTTP.IOExtras",
    "category": "Module",
    "text": "This module defines extensions to the Base.IO interface to support:\n\nan unread! function for pushing excess bytes back into a stream,\nstartwrite, closewrite, startread and closeread for streams  with transactional semantics.\n\n\n\n"
},

{
    "location": "index.html#HTTP.IOExtras.unread!",
    "page": "Home",
    "title": "HTTP.IOExtras.unread!",
    "category": "Function",
    "text": "unread!(::Transaction, bytes)\n\nPush bytes back into a connection's excess buffer (to be returned by the next read).\n\n\n\nunread!(::IO, bytes)\n\nPush bytes back into a connection (to be returned by the next read).\n\n\n\n"
},

{
    "location": "index.html#HTTP.IOExtras.startwrite-Tuple{IO}",
    "page": "Home",
    "title": "HTTP.IOExtras.startwrite",
    "category": "Method",
    "text": "startwrite(::IO)\nclosewrite(::IO)\nstartread(::IO)\ncloseread(::IO)\n\nSignal start/end of write or read operations.\n\n\n\n"
},

{
    "location": "index.html#HTTP.IOExtras.isioerror",
    "page": "Home",
    "title": "HTTP.IOExtras.isioerror",
    "category": "Function",
    "text": "isioerror(exception)\n\nIs exception caused by a possibly recoverable IO error.\n\n\n\n"
},

{
    "location": "index.html#IOExtras-Interface-1",
    "page": "Home",
    "title": "IOExtras Interface",
    "category": "section",
    "text": "HTTP.IOExtras\nHTTP.IOExtras.unread!\nHTTP.IOExtras.startwrite(::IO)\nHTTP.IOExtras.isioerror"
},

{
    "location": "index.html#HTTP.Streams.closebody",
    "page": "Home",
    "title": "HTTP.Streams.closebody",
    "category": "Function",
    "text": "closebody(::Stream)\n\nWrite the final 0 chunk if needed.\n\n\n\n"
},

{
    "location": "index.html#HTTP.Streams.isaborted",
    "page": "Home",
    "title": "HTTP.Streams.isaborted",
    "category": "Function",
    "text": "isaborted(::Stream{Response})\n\nHas the server signaled that it does not wish to receive the message body?\n\n\"If [the response] indicates the server does not wish to receive the  message body and is closing the connection, the client SHOULD  immediately cease transmitting the body and close the connection.\" RFC7230, 6.5\n\n\n\n"
},

{
    "location": "index.html#Streams-Interface-1",
    "page": "Home",
    "title": "Streams Interface",
    "category": "section",
    "text": "HTTP.Streams.closebody\nHTTP.Streams.isaborted"
},

{
    "location": "index.html#HTTP.ConnectionPool.Connection",
    "page": "Home",
    "title": "HTTP.ConnectionPool.Connection",
    "category": "Type",
    "text": "Connection{T <: IO}\n\nA TCPSocket or SSLContext connection to a HTTP host and port.\n\nFields:\n\nhost::String\nport::String, exactly as specified in the URI (i.e. may be empty).\npipeline_limit, number of requests to send before waiting for responses.\npeerport, remote TCP port number (used for debug messages).\nlocalport, local TCP port number (used for debug messages).\nio::T, the TCPSocket or `SSLContext.\nexcess::ByteView, left over bytes read from the connection after  the end of a response message. These bytes are probably the start of the  next response message.\nsequence, number of most recent Transaction.\nwritecount, number of Messages that have been written.\nwritedone, signal that writecount was incremented.\nreadcount, number of Messages that have been read.\nreaddone, signal that readcount was incremented.\ntimestamp, time data was last recieved.\nparser::Parser, reuse a Parser when this Connection is reused.\n\n\n\n"
},

{
    "location": "index.html#HTTP.ConnectionPool.Transaction",
    "page": "Home",
    "title": "HTTP.ConnectionPool.Transaction",
    "category": "Type",
    "text": "A single pipelined HTTP Request/Response transaction`.\n\nFields:\n\nc, the shared Connection used for this Transaction.\nsequence::Int, identifies this Transaction among the others that share c.\n\n\n\n"
},

{
    "location": "index.html#HTTP.ConnectionPool.pool",
    "page": "Home",
    "title": "HTTP.ConnectionPool.pool",
    "category": "Constant",
    "text": "The pool is a collection of open Connections.  The request function calls getconnection to retrieve a connection from the pool.  When the request function has written a Request Message it calls closewrite to signal that the Connection can be reused for writing (to send the next Request). When the request function has read the Response Message it calls closeread to signal that the Connection can be reused for reading.\n\n\n\n"
},

{
    "location": "index.html#HTTP.ConnectionPool.getconnection",
    "page": "Home",
    "title": "HTTP.ConnectionPool.getconnection",
    "category": "Function",
    "text": "getconnection(type, host, port) -> Connection\n\nFind a reusable Connection in the pool, or create a new Connection if required.\n\n\n\n"
},

{
    "location": "index.html#HTTP.IOExtras.unread!-Tuple{HTTP.ConnectionPool.Transaction,SubArray{UInt8,1,Array{UInt8,1},Tuple{UnitRange{Int64}},true}}",
    "page": "Home",
    "title": "HTTP.IOExtras.unread!",
    "category": "Method",
    "text": "unread!(::Transaction, bytes)\n\nPush bytes back into a connection's excess buffer (to be returned by the next read).\n\n\n\n"
},

{
    "location": "index.html#HTTP.IOExtras.startwrite-Tuple{HTTP.ConnectionPool.Transaction}",
    "page": "Home",
    "title": "HTTP.IOExtras.startwrite",
    "category": "Method",
    "text": "startwrite(::Transaction)\n\nWait for prior pending writes to complete.\n\n\n\n"
},

{
    "location": "index.html#HTTP.IOExtras.closewrite-Tuple{HTTP.ConnectionPool.Transaction}",
    "page": "Home",
    "title": "HTTP.IOExtras.closewrite",
    "category": "Method",
    "text": "closewrite(::Transaction)\n\nSignal that an entire Request Message has been written to the Transaction.\n\n\n\n"
},

{
    "location": "index.html#HTTP.IOExtras.startread-Tuple{HTTP.ConnectionPool.Transaction}",
    "page": "Home",
    "title": "HTTP.IOExtras.startread",
    "category": "Method",
    "text": "startread(::Transaction)\n\nWait for prior pending reads to complete.\n\n\n\n"
},

{
    "location": "index.html#HTTP.IOExtras.closeread-Tuple{HTTP.ConnectionPool.Transaction}",
    "page": "Home",
    "title": "HTTP.IOExtras.closeread",
    "category": "Method",
    "text": "closeread(::Transaction)\n\nSignal that an entire Response Message has been read from the Transaction.\n\nIncrement readcount and wake up tasks waiting in startread.\n\n\n\n"
},

{
    "location": "index.html#Connection-Pooling-Interface-1",
    "page": "Home",
    "title": "Connection Pooling Interface",
    "category": "section",
    "text": "HTTP.ConnectionPool.Connection\nHTTP.ConnectionPool.Transaction\nHTTP.ConnectionPool.pool\nHTTP.ConnectionPool.getconnection\nHTTP.IOExtras.unread!(::HTTP.ConnectionPool.Transaction,::SubArray{UInt8,1,Array{UInt8,1},Tuple{UnitRange{Int64}},true})\nHTTP.IOExtras.startwrite(::HTTP.ConnectionPool.Transaction)\nHTTP.IOExtras.closewrite(::HTTP.ConnectionPool.Transaction)\nHTTP.IOExtras.startread(::HTTP.ConnectionPool.Transaction)\nHTTP.IOExtras.closeread(::HTTP.ConnectionPool.Transaction)"
},

]}
