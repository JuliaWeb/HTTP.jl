using Base.Test

#TODO:
 # make more @testsets!!
 # do a "codepath" @testset!!
 # make sure we send request cookies in write(tcp, request)
 # handle other body types for request sending, Vector{UInt8}, String, IO, FIFOBuffer
 # try to type parser.data as ::Union{RequestParser,ResponseParser}
 # @code_warntype functions to find anything fishy
 # benchmark vs. Requests and python requests?
 # docs
 # spec tests
 # cleanup cookies.jl file to get server-side stuff done
 ####### v0.1 LINE
 # proxy stuff
 # multi-part encoded files
 # response caching?
 # digest authentication
 # auto-gzip response

for sch in ("http", "https")

    @test HTTP.get("$sch://httpbin.org/ip").status == 200
    @test HTTP.head("$sch://httpbin.org/ip").status == 200
    @test HTTP.options("$sch://httpbin.org/ip").status == 200
    @test HTTP.post("$sch://httpbin.org/ip").status == 405
    @test HTTP.post("$sch://httpbin.org/post").status == 200
    @test HTTP.put("$sch://httpbin.org/put").status == 200
    @test HTTP.delete("$sch://httpbin.org/delete").status == 200
    @test HTTP.patch("$sch://httpbin.org/patch").status == 200

    @test HTTP.get("$sch://httpbin.org/encoding/utf8").status == 200

    # HTTP.connect("$sch://httpbin.org/connect")
    # @test HTTP.trace("$sch://httpbin.org/trace").status == 200

    HTTP.get("$sch://httpbin.org/cookies/set?hey=sailor")
    HTTP.get("$sch://httpbin.org/cookies")
# begin
#     r = HTTP.get("$sch://httpbin.org/stream/100"; stream=true)
#     println("Body has $(r.body.nb) bytes of data...")
#     sleep(0.1)
#     println("Body has $(r.body.nb) bytes of data...")
#     sleep(0.1)
#     println("Body has $(r.body.nb) bytes of data...")
#     println(String(readavailable(r.body)))
#     sleep(0.1)
#     println("Body has $(r.body.nb) bytes of data...")
#     sleep(0.1)
#     println("Body has $(r.body.nb) bytes of data...")
#     sleep(0.1)
#     println(String(readavailable(r.body)))
# end

    # redirects
    r = HTTP.get("$sch://httpbin.org/redirect/1")
    @test r.status == 200
    @test length(r.history) == 1
    @test_throws HTTP.RedirectException HTTP.get("$sch://httpbin.org/redirect/6")
    @test HTTP.get("$sch://httpbin.org/relative-redirect/1").status == 200
    @test HTTP.get("$sch://httpbin.org/absolute-redirect/1").status == 200
    @test HTTP.get("$sch://httpbin.org/redirect-to?url=http%3A%2F%2Fexample.com").status == 200

    @test HTTP.post("$sch://httpbin.org/post"; body="√").status == 200
    @test HTTP.get("$sch://user:pwd@httpbin.org/basic-auth/user/pwd").status == 200
    @test HTTP.get("$sch://user:pwd@httpbin.org/hidden-basic-auth/user/pwd").status == 200

    @test_throws HTTP.TimeoutException HTTP.get("$sch://httpbin.org/delay/3"; readtimeout=1.0)
end


body = """{"username":"jacob.quinn@domo.com","password":"R29sZG1vdXNlNTYh","base64":true}"""
r = HTTP.post("https://tateboys.domo.com/api/domoweb/auth/login"; body=body)
client = HTTP.DEFAULT_CLIENT
cookies = client.cookies["tateboys.domo.com"]
c = cookies[1]
HTTP.shouldsend(c, true, "domo.domo.com", "/api/content/v3/users")
@time rr = HTTP.get("https://tateboys.domo.com/api/query/v1/execute/export/6ad6fbc5-2c8c-4381-b703-49c57cd38f2a?accept=text%2Fcsv&includeHeader=true&fileName=TireShop+Inventry.csv"; verbose=false)

@time begin
    rr = HTTP.get("https://tateboys.domo.com/api/query/v1/execute/export/6ad6fbc5-2c8c-4381-b703-49c57cd38f2a?accept=text%2Fcsv&includeHeader=true&fileName=TireShop+Inventry.csv"; stream=true, verbose=false)
    while !eof(rr.body)
        bytes = readavailable(rr.body)
        # println("read $(length(bytes)) bytes...")
        isempty(bytes) && wait(rr.body)
    end
end
