<<<<<<< HEAD
using HTTP, Base.Test

include("uri.jl")
include("parser.jl")

server_task = @async HTTP.serve()

client = connect("127.0.0.1:8081")
write(client, "OPTIONS * HTTP/1.1\r\n\r\n")
sleep(1)
resp = String(readavailable(client))

# reject invalid HTTP versions

# test a variety of invalid requests (see http_parser error codes?)
  # invalid METHOD (501 not implemented status)
  # URI too long (414 status)
  # invalid HTTP versions
  # whitespace where there shouldn't be
  # non-encoded target resource w/ spaces (return 400)
  # duplicate headers
  # no space between header field name and colon
  # reject obs-fold multi-line header field values (400 bad request)


# limit on overall header size? body size?

# no response body
 # HEAD requests
 # 1xx and 2xx responses
 # CONNECT requests
 # 204, 304

# no transfer-encoding header in response to:
 # 1xx or 204 response statuses
 # CONNECT request

# unsupported transfer-endcoding => 501 not implemented

# bad request 400 on multiple Content-Length headers

# timeout and close connection when bytes received don't match Content-Length from client

# https://tools.ietf.org/html/rfc7230#section-3.5
# ignore preceeding CRLF to request-line

# https://tools.ietf.org/html/rfc7230#section-4.1.1
# ignore unsupported chunk-extensions

# https://tools.ietf.org/html/rfc7230#section-4.1.2
# chunk trailer headers are handled appropriately

# https://tools.ietf.org/html/rfc7230#section-4.2
# transfer-encodings supported: compress, deflate, gzip, x-gzip

# https://tools.ietf.org/html/rfc7230#section-5.4
# 400 for no Host or multiple Host headers

# https://tools.ietf.org/html/rfc7230#section-6.1
# test keep-alive support

# https://tools.ietf.org/html/rfc7230#section-6.5
# test an inactive client (i.e. sent keep-alive, but didn't send anything else)
=======
using Compat
using Requests
using JSON
using Base.Test
using Libz

import Requests: get, post, put, delete, options, bytes, text, json, history

# simple calls, no headers, data or query params -------

@test get("http://httpbin.org/get").status == 200
@test post("http://httpbin.org/post").status == 200
@test put("http://httpbin.org/put").status == 200
@test delete("http://httpbin.org/delete").status == 200
@test options("http://httpbin.org/get").status == 200


# check query params -------

data = json(get("http://httpbin.org/get";
                      query = Dict("key1" => "value1",
                                   "key with spaces" => "value with spaces",
                                   "key2" => ["value2.1", "value2.2"])))
@test data["args"]["key1"] == "value1"
@test data["args"]["key with spaces"] == "value with spaces"
@test data["args"]["key2"] == ["value2.1", "value2.2"]

data = json(post("http://httpbin.org/post";
                       query = Dict("key1" => "value1",
                                            "key2" => "value2",
                                            "key with spaces" => "value with spaces")))
@test data["args"]["key1"] == "value1"
@test data["args"]["key2"] == "value2"
@test data["args"]["key with spaces"] == "value with spaces"

data = json(put("http://httpbin.org/put";
                      query = Dict("key1" => "value1",
                                   "key2" => "value2",
                                   "key3" => 3,
                                   "key with spaces" => "value with spaces")))
@test data["args"]["key1"] == "value1"
@test data["args"]["key2"] == "value2"
@test data["args"]["key3"] == "3"
@test data["args"]["key with spaces"] == "value with spaces"

data = json(delete("http://httpbin.org/delete";
                         query = Dict("key1" => "value1",
                                      "key4" => 4.01,
                                      "key with spaces" => "value with spaces")))
@test data["args"]["key1"] == "value1"
@test data["args"]["key4"] == "4.01"
@test data["args"]["key with spaces"] == "value with spaces"

response = options("http://httpbin.org/get";
                          query = Dict("key1" => "value1",
                                       "key2" => "value2",
                                       "key3" => 3,
                                       "key4" => 4.01))
@test length(response.data) == 0


# check data -------

data = json(post("http://httpbin.org/post";
                       json = Dict("key1" => "value1",
                                    "key2" => "value2")))
@test data["json"]["key1"] == "value1"
@test data["json"]["key2"] == "value2"

data = json(put("http://httpbin.org/put";
                      json = Dict("key1" => "value1",
                                  "key2" => "value2",
                                  "key3" => 3)))
@test data["json"]["key1"] == "value1"
@test data["json"]["key2"] == "value2"
@test data["json"]["key3"] == 3

data = json(delete("http://httpbin.org/delete";
                         json = Dict("key1" => "value1",
                                    "key4" => 4.01)))
@test data["json"]["key1"] == "value1"
@test data["json"]["key4"] == 4.01

# form-encoded posts
data = json(post("http://httpbin.org/post", data=Dict("email"=>"a@b.com")))
@test data["form"]["email"] == "a@b.com"

# query + data -------

data = json(post("http://httpbin.org/post";
                       query = (Dict("qkey1" => "value1",
                                     "qkey2" => "value2")),
                       json = (Dict("dkey1" => "data1",
                                    "dkey2" => "data2"))))
@test data["args"]["qkey1"] == "value1"
@test data["args"]["qkey2"] == "value2"
@test data["json"]["dkey1"] == "data1"
@test data["json"]["dkey2"] == "data2"

data = json(put("http://httpbin.org/put";
                      query = (Dict("qkey1" => "value1",
                                    "qkey2" => "value2",
                                    "qkey3" => 3)),
                      json = (Dict("dkey1" => "data1",
                                    "dkey2" => "data2",
                                    "dkey3" => 5))))
@test data["args"]["qkey1"] == "value1"
@test data["args"]["qkey2"] == "value2"
@test data["args"]["qkey3"] == "3"
@test data["json"]["dkey1"] == "data1"
@test data["json"]["dkey2"] == "data2"
@test data["json"]["dkey3"] == 5

data = json(delete("http://httpbin.org/delete";
                         query = (Dict("qkey1" => "value1",
                                       "qkey4" => 4.01)),
                         json = (Dict("dkey1" => "data1",
                                      "dkey2" => 9.01))))
@test data["args"]["qkey1"] == "value1"
@test data["args"]["qkey4"] == "4.01"
@test data["json"]["dkey1"] == "data1"
@test data["json"]["dkey2"] == 9.01

data = json(post(URI("http://httpbin.org/post");
                       data = "√",
                       headers = Dict("Content-Type" => "text/plain")))

@test data["data"] == "√"

# Test custom content type
data = json(post("http://httpbin.org/post",
             data="{\"a\": \"b\"}",
             headers=Dict("Content-Type"=>"application/json")))
@test data["json"]["a"] == "b"

# Test file upload
filename = Base.source_path()

files = [
  FileParam(readstring(filename),"text/julia","file1","runtests.jl"),
  FileParam(open(filename,"r"),"text/julia","file2","runtests.jl",true),
  FileParam(IOBuffer(readstring(filename)),"text/julia","file3","runtests.jl"),
  ]

res = post(URI("http://httpbin.org/post"); files = files)

filecontent = readstring(filename)
data = json(res)
@test data["files"]["file1"] == filecontent
@test data["files"]["file2"] == filecontent
@test data["files"]["file3"] == filecontent

# Test for chunked responses (we expect 100 from split as there are 99 '\n')
@test size(split(text(get("http://httpbin.org/stream/99")), "\n"), 1) == 100

# Test for gzipped responses
@test json(get("http://httpbin.org/gzip"))["gzipped"] == true
@test json(get("http://httpbin.org/deflate"))["deflated"] == true
@test json(get("http://httpbin.org/headers"; compressed=true))["headers"]["Accept-Encoding"] == "gzip, deflate"

# Test for gzipped requests
foo_result = "data:application/octet-stream;base64," * (Vector{UInt8}("foo") |> ZlibDeflateInputStream |> read |> base64encode)
@test json(post("http://httpbin.org/post"; data="foo", gzip_data=true))["data"] == foo_result
@test json(post("http://httpbin.org/post"; data=Vector{UInt8}("foo"), gzip_data=true))["data"] == foo_result

# Test timeout delay
let
    timeout = Dates.Millisecond(500)
    @test_throws Requests.TimeoutException get("http://httpbin.org/delay/3", timeout=timeout)
end

# Test cookies
let
    r = get("http://httpbin.org/cookies/set?a=1&b=2", allow_redirects=false)
    cookies = r.cookies
    @test length(cookies) == 2
    @test cookies["a"].value == "1"
    @test cookies["b"].value == "2"
    @test cookies["a"].attrs["Path"] == "/"
    r = json(get("http://httpbin.org/cookies", cookies=cookies))
    @test r["cookies"]["a"] == "1"
    @test r["cookies"]["b"] == "2"
end

# Test redirects
let
    r = get("http://httpbin.org/absolute-redirect/3")
    @test length(history(r)) == 3
    r = get("http://httpbin.org/relative-redirect/3")
    @test length(history(r)) == 3
    @test_throws Requests.RedirectException get("http://httpbin.org/redirect/3", max_redirects=1)
end

# Test HTTPS
@test statuscode(get("https://httpbin.org")) == 200

# Test output streaming
let
    stream = Requests.post_streaming(
      "http://httpbin.org/post", write_body=false,
      headers=Dict("Transfer-Encoding"=>"chunked"))

    write_chunked(stream, "ab")
    write_chunked(stream, "cde")
    write_chunked(stream, "")

    response = JSON.parse(readstring(stream))
    @test response["data"] == "abcde"
end


# Test input streaming
let
    stream = Requests.get_streaming("http://httpbin.org/stream-bytes/100", query=Dict(:chunk_size=>10))
    N = 0
    while !eof(stream)
        bytes = readavailable(stream)
        N += length(bytes)
    end
    @test N==100
end

# Proxy testing. Would be better to use a real proxy instead of using the real site
# as the "proxy", but hard to find a reliable unmetered public proxy for testing.

@test get("http://httpbin.org/get"; proxy=Nullable(URI("http://httpbin.org"))).status == 200

# Test proxy settings via local squid Docker container if REQUESTS_TEST_PROXY is set to 1
# before testing.
# Requires Docker and docker-machine (obtainable via Docker toolbox)
if get(ENV, "REQUESTS_TEST_PROXY", "0") == "1"
    run(`docker-machine create -d virtualbox proxytest`)
    cmds = readstring(`docker-machine env proxytest`)
    for line in split(cmds, '\n')
        m = match(r"export (?<name>.*?)=(?<val>.*)", line)
        m===nothing && continue
        ENV[m[:name]] = m[:val]
    end
    @show ENV
    run(`docker run --name squid -d --restart=always -p 3128:3128 quay.io/sameersbn/squid:3.3.8-2`)
    ip = IPv4(readstring(`docker-machine ip proxytest`))
    proxy_vars = ["http_proxy", "https_proxy"]
    for var in proxy_vars
        ENV[var] = "http://$ip:3128"
    end
    ENV["REQUESTS_TEST_PROXY"] = "0"
    Pkg.test("Requests")
    ENV["REQUESTS_TEST_PROXY"] = "1"
    for var in proxy_vars
        pop!(ENV, var)
    end
    run(`docker stop squid`)
    run(`docker rm -v squid`)
    run(`docker-machine rm proxytest`)
end

# Basic auth
@test get("https://user:pw@httpbin.org/basic-auth/user/pw").status == 200
@test get("https://user:wrongpw@httpbin.org/basic-auth/user/pw").status == 401
>>>>>>> c368db55e017eebd8318471272d8b6851d56359d
