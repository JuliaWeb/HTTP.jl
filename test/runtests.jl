
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

data = JSON.parse(get("http://httpbin.org/get"; query = {"key1" => "value1"}).data)
@test data["args"]["key1"] == "value1"

data = JSON.parse(post("http://httpbin.org/post"; query = {"key1" => "value1",
                                                           "key2" => "value2" }).data)
@test data["args"]["key1"] == "value1"
@test data["args"]["key2"] == "value2"

data = JSON.parse(put("http://httpbin.org/put"; query = {"key1" => "value1",
                                                         "key2" => "value2",
                                                         "key3" => 3 }).data)
@test data["args"]["key1"] == "value1"
@test data["args"]["key2"] == "value2"
@test data["args"]["key3"] == "3"

data = JSON.parse(delete("http://httpbin.org/delete"; query = {"key1" => "value1",
                                                               "key4" => 4.01 }).data)
@test data["args"]["key1"] == "value1"
@test data["args"]["key4"] == "4.01"

data = JSON.parse(options("http://httpbin.org/get"; query = {"key1" => "value1",
                                                             "key2" => "value2",
                                                             "key3" => 3,
                                                             "key4" => 4.01 }).data)
@test data == nothing


#check data -------

data = JSON.parse(post("http://httpbin.org/post"; data = {"key1" => "value1",
                                                           "key2" => "value2" }).data)
@test data["json"]["key1"] == "value1"
@test data["json"]["key2"] == "value2"

data = JSON.parse(put("http://httpbin.org/put"; data = {"key1" => "value1",
                                                         "key2" => "value2",
                                                         "key3" => 3 }).data)
@test data["json"]["key1"] == "value1"
@test data["json"]["key2"] == "value2"
@test data["json"]["key3"] == 3

data = JSON.parse(delete("http://httpbin.org/delete"; data = {"key1" => "value1",
                                                               "key4" => 4.01 }).data)
@test data["json"]["key1"] == "value1"
@test data["json"]["key4"] == 4.01



