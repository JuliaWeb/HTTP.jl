using Requests
using JSON
using Base.Test

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
                                   "key with spaces" => "value with spaces")))
@test data["args"]["key1"] == "value1"
@test data["args"]["key with spaces"] == "value with spaces"

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

data = json(options("http://httpbin.org/get";
                          query = Dict("key1" => "value1",
                                       "key2" => "value2",
                                       "key3" => 3,
                                       "key4" => 4.01)))
@test data == nothing


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

# Test file upload
filename = Base.source_path()

files = [
  FileParam(readall(filename),"text/julia","file1","runtests.jl"),
  FileParam(open(filename,"r"),"text/julia","file2","runtests.jl",true),
  FileParam(IOBuffer(readall(filename)),"text/julia","file3","runtests.jl"),
  ]

res = post(URI("http://httpbin.org/post"); files = files)

filecontent = readall(filename)
data = json(res)
@test data["files"]["file1"] == filecontent
@test data["files"]["file2"] == filecontent
@test data["files"]["file3"] == filecontent

# Test for chunked responses (we expect 100 from split as there are 99 '\n')
@test size(split(text(get("http://httpbin.org/stream/99")), "\n"), 1) == 100

# Test for gzipped responses
@test json(get("http://httpbin.org/gzip"))["gzipped"] == true
@test json(get("http://httpbin.org/deflate"))["deflated"] == true

# Test timeout delay
let
    timeout = Dates.Millisecond(500)
    @test_throws Requests.TimeoutException get("http://httpbin.org/delay/1", timeout=timeout)
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

# Test streaming
let
    stream = Requests.get_streaming("http://httpbin.org/stream-bytes/100", query=Dict(:chunk_size=>10))
    N = 0
    while !eof(stream)
        bytes = readavailable(stream)
        N += length(bytes)
    end
    @test N==100
end
