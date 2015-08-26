
using Compat
using Requests
using JSON
using Base.Test


# simple calls, no headers, data or query params -------

@test get("http://httpbin.org/get").status === 200
@test post("http://httpbin.org/post").status === 200
@test put("http://httpbin.org/put").status === 200
@test delete("http://httpbin.org/delete").status === 200
@test options("http://httpbin.org/get").status === 200


# check query params -------

data = jsondata(get("http://httpbin.org/get";
                      query = @compat Dict("key1" => "value1",
                                           "key with spaces" => "value with spaces")))
@test data["args"]["key1"] == "value1"
@test data["args"]["key with spaces"] == "value with spaces"

data = jsondata(post("http://httpbin.org/post";
                       query = @compat Dict("key1" => "value1",
                                            "key2" => "value2",
                                            "key with spaces" => "value with spaces")))
@test data["args"]["key1"] == "value1"
@test data["args"]["key2"] == "value2"
@test data["args"]["key with spaces"] == "value with spaces"

data = jsondata(put("http://httpbin.org/put";
                      query = @compat Dict("key1" => "value1",
                                           "key2" => "value2",
                                           "key3" => 3,
                                           "key with spaces" => "value with spaces")))
@test data["args"]["key1"] == "value1"
@test data["args"]["key2"] == "value2"
@test data["args"]["key3"] == "3"
@test data["args"]["key with spaces"] == "value with spaces"

data = jsondata(delete("http://httpbin.org/delete";
                         query = @compat Dict("key1" => "value1",
                                              "key4" => 4.01,
                                              "key with spaces" => "value with spaces")))
@test data["args"]["key1"] == "value1"
@test data["args"]["key4"] == "4.01"
@test data["args"]["key with spaces"] == "value with spaces"

data = jsondata(options("http://httpbin.org/get";
                          query = @compat Dict("key1" => "value1",
                                               "key2" => "value2",
                                               "key3" => 3,
                                               "key4" => 4.01)))
@test data == nothing


# check data -------

data = jsondata(post("http://httpbin.org/post";
                       json = @compat Dict("key1" => "value1",
                                           "key2" => "value2")))
@test data["json"]["key1"] == "value1"
@test data["json"]["key2"] == "value2"

data = jsondata(put("http://httpbin.org/put";
                      json = @compat Dict("key1" => "value1",
                                          "key2" => "value2",
                                          "key3" => 3)))
@test data["json"]["key1"] == "value1"
@test data["json"]["key2"] == "value2"
@test data["json"]["key3"] == 3

data = jsondata(delete("http://httpbin.org/delete";
                         json = @compat Dict("key1" => "value1",
                                             "key4" => 4.01)))
@test data["json"]["key1"] == "value1"
@test data["json"]["key4"] == 4.01


# query + data -------

data = jsondata(post("http://httpbin.org/post";
                       query = (@compat Dict("qkey1" => "value1",
                                             "qkey2" => "value2")),
                       json = (@compat Dict("dkey1" => "data1",
                                            "dkey2" => "data2"))))
@test data["args"]["qkey1"] == "value1"
@test data["args"]["qkey2"] == "value2"
@test data["json"]["dkey1"] == "data1"
@test data["json"]["dkey2"] == "data2"

data = jsondata(put("http://httpbin.org/put";
                      query = (@compat Dict("qkey1" => "value1",
                                            "qkey2" => "value2",
                                            "qkey3" => 3)),
                      json = (@compat Dict("dkey1" => "data1",
                                           "dkey2" => "data2",
                                           "dkey3" => 5))))
@test data["args"]["qkey1"] == "value1"
@test data["args"]["qkey2"] == "value2"
@test data["args"]["qkey3"] == "3"
@test data["json"]["dkey1"] == "data1"
@test data["json"]["dkey2"] == "data2"
@test data["json"]["dkey3"] == 5

data = jsondata(delete("http://httpbin.org/delete";
                         query = (@compat Dict("qkey1" => "value1",
                                               "qkey4" => 4.01)),
                         json = (@compat Dict("dkey1" => "data1",
                                              "dkey2" => 9.01))))
@test data["args"]["qkey1"] == "value1"
@test data["args"]["qkey4"] == "4.01"
@test data["json"]["dkey1"] == "data1"
@test data["json"]["dkey2"] == 9.01

data = jsondata(post(URI("http://httpbin.org/post");
                       data = "√",
                       headers = @compat Dict("Content-Type" => "text/plain")))

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
data = jsondata(res)
@test data["files"]["file1"] == filecontent
@test data["files"]["file2"] == filecontent
@test data["files"]["file3"] == filecontent

# Test for chunked responses (we expect 100 from split as there are 99 '\n')
@test size(split(textdata(get("http://httpbin.org/stream/99")), "\n"), 1) == 100

# Test for gzipped responses
@test jsondata(get("http://httpbin.org/gzip"))["gzipped"] == true
@test jsondata(get("http://httpbin.org/deflate"))["deflated"] == true

# Test timeout delay
let
    if VERSION > v"0.4-"
        timeout = Dates.Millisecond(500)
    else
        timeout = .5
    end
    @test_throws Requests.TimeoutException get("http://httpbin.org/delay/1", timeout=timeout)
end

# Test cookies
let
    r = get("http://httpbin.org/cookies/set?a=1&b=2")
    cookies = r.cookies
    @test length(cookies) == 2
    @test cookies["a"].value == "1"
    @test cookies["b"].value == "2"
    @test cookies["a"].attrs["Path"] == "/"
    r = get("http://httpbin.org/cookies", cookies=cookies).data |> JSON.parse
    @test r["cookies"]["a"] == "1"
    @test r["cookies"]["b"] == "2"
end
