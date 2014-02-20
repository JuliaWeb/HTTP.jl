
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

data = JSON.parse(get("http://httpbin.org/get"; query = { "key1" => "value1",
                                                          "key with spaces" => "value with spaces"}).data)
@test data["args"]["key1"] == "value1"
@test data["args"]["key with spaces"] == "value with spaces"

data = JSON.parse(post("http://httpbin.org/post"; query = { "key1" => "value1",
                                                            "key2" => "value2",
                                                            "key with spaces" => "value with spaces"}).data)
@test data["args"]["key1"] == "value1"
@test data["args"]["key2"] == "value2"
@test data["args"]["key with spaces"] == "value with spaces"

data = JSON.parse(put("http://httpbin.org/put"; query = { "key1" => "value1",
                                                          "key2" => "value2",
                                                          "key3" => 3,
                                                          "key with spaces" => "value with spaces"}).data)
@test data["args"]["key1"] == "value1"
@test data["args"]["key2"] == "value2"
@test data["args"]["key3"] == "3"
@test data["args"]["key with spaces"] == "value with spaces"

data = JSON.parse(delete("http://httpbin.org/delete"; query = { "key1" => "value1",
                                                                "key4" => 4.01,
                                                                "key with spaces" => "value with spaces"}).data)
@test data["args"]["key1"] == "value1"
@test data["args"]["key4"] == "4.01"
@test data["args"]["key with spaces"] == "value with spaces"

data = JSON.parse(options("http://httpbin.org/get"; query = { "key1" => "value1",
                                                              "key2" => "value2",
                                                              "key3" => 3,
                                                              "key4" => 4.01 }).data)
@test data == nothing


# check data -------

data = JSON.parse(post("http://httpbin.org/post"; data = { "key1" => "value1",
                                                           "key2" => "value2" }).data)
@test data["json"]["key1"] == "value1"
@test data["json"]["key2"] == "value2"

data = JSON.parse(put("http://httpbin.org/put"; data = { "key1" => "value1",
                                                         "key2" => "value2",
                                                         "key3" => 3 }).data)
@test data["json"]["key1"] == "value1"
@test data["json"]["key2"] == "value2"
@test data["json"]["key3"] == 3

data = JSON.parse(delete("http://httpbin.org/delete"; data = { "key1" => "value1",
                                                               "key4" => 4.01 }).data)
@test data["json"]["key1"] == "value1"
@test data["json"]["key4"] == 4.01


# query + data -------

data = JSON.parse(post("http://httpbin.org/post"; query = { "qkey1" => "value1",
                                                            "qkey2" => "value2" },
                                                  data = { "dkey1" => "data1",
                                                           "dkey2" => "data2" }).data)
@test data["args"]["qkey1"] == "value1"
@test data["args"]["qkey2"] == "value2"
@test data["json"]["dkey1"] == "data1"
@test data["json"]["dkey2"] == "data2"

data = JSON.parse(put("http://httpbin.org/put"; query = { "qkey1" => "value1",
                                                          "qkey2" => "value2",
                                                          "qkey3" => 3 },
                                                data = { "dkey1" => "data1",
                                                         "dkey2" => "data2",
                                                         "dkey3" => 5 }).data)
@test data["args"]["qkey1"] == "value1"
@test data["args"]["qkey2"] == "value2"
@test data["args"]["qkey3"] == "3"
@test data["json"]["dkey1"] == "data1"
@test data["json"]["dkey2"] == "data2"
@test data["json"]["dkey3"] == 5

data = JSON.parse(delete("http://httpbin.org/delete"; query = { "qkey1" => "value1",
                                                                "qkey4" => 4.01 },
                                                      data = { "dkey1" => "data1",
                                                               "dkey2" => 9.01 }).data)
@test data["args"]["qkey1"] == "value1"
@test data["args"]["qkey4"] == "4.01"
@test data["json"]["dkey1"] == "data1"
@test data["json"]["dkey2"] == 9.01
