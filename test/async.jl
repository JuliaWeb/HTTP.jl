using JSON
using MbedTLS: digest, MD_MD5, MD_SHA256
using Base64

using HTTP.IOExtras
using HTTP.request

println("async tests")

@async while true
    sleep(10)
    HTTP.ConnectionPool.showpool(STDOUT)
end



# Tiny S3 interface...
s3region = "ap-southeast-2"
s3url = "https://s3.$s3region.amazonaws.com"
s3(method, path, body=UInt8[]; kw...) =
    request(method, "$s3url/$path", [], body; awsauthorization=true, kw...)
s3get(path; kw...) = s3("GET", path; kw...)
s3put(path, data; kw...) = s3("PUT", path, data; kw...)

function create_bucket(bucket)
    s3put(bucket, """
        <CreateBucketConfiguration
                     xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <LocationConstraint>$s3region</LocationConstraint>
        </CreateBucketConfiguration>""",
        statusexception=false)
end

create_bucket("http.jl.test")

function dump_async_exception(e, st)
    buf = IOBuffer()
    write(buf, "==========\n@async exception:\n==========\n")
    show(buf, "text/plain", e)
    show(buf, "text/plain", st)
    write(buf, "==========\n\n")
    print(String(take!(buf)))
end

@testset "async s3 $count, $http" for count in [10, 100, 1000, 2000],
                                       http in ["http", "https"]

s3url = "$http://s3.$s3region.amazonaws.com"
println("running async s3 $count $http")

put_data_sums = Dict()
sz = 10000
ch = 100
@sync for i = 1:count
    data = rand(UInt8, sz)
    md5 = bytes2hex(digest(MD_MD5, data))
    put_data_sums[i] = md5
    @async try
        url = "$s3url/http.jl.test/file$i"
        r = HTTP.open("PUT", url, ["Content-Length" => sz];
                body_sha256=digest(MD_SHA256, data),
                body_md5=digest(MD_MD5, data),
                awsauthorization=true) do http
            for n = 1:ch:sz
                write(http, data[n:n+(ch-1)])
                sleep(rand(1:10)/1000)
            end
        end
        #println("S3 put file$i")
        @assert strip(HTTP.header(r, "ETag"), '"') == md5
    catch e
        dump_async_exception(e, catch_stacktrace())
    end
end

get_data_sums = Dict()
@sync for i = 1:count
    @async try
        url = "$s3url/http.jl.test/file$i"
        buf = IOBuffer()
        r = HTTP.open("GET", url;
                      awsauthorization=true,
                      reuse_limit = 120) do http
            while !eof(http)
                write(buf, readavailable(http))
                sleep(rand(1:10)/1000)
            end
        end
        #println("S3 get file$i")
        md5 = bytes2hex(digest(MD_MD5, take!(buf)))
        @assert strip(HTTP.header(r, "ETag"), '"') == md5
        get_data_sums[i] = md5
    catch e
        dump_async_exception(e, catch_stacktrace())
    end
end

for i = 1:count
    @test put_data_sums[i] == get_data_sums[i]
end

end

configs = [
    [],
    [:reuse_limit => 200],
    [:reuse_limit => 100],
    [:reuse_limit => 10]
]

@testset "async $count, $num, $config, $http" for count in 1:3,
                                            num in [10, 100, 1000, 2000],
                                            config in configs,
                                            http in ["http", "https"]

println("running async $count, 1:$num, $config, $http")



    result = []
    @sync begin
        for i = 1:min(num,100)
            @async try
                r = HTTP.request("GET",
                 "$http://httpbin.org/headers", ["i" => i]; config...)
                r = JSON.parse(String(r.body))
                push!(result, r["headers"]["I"] => string(i))
            catch e
                dump_async_exception(e, catch_stacktrace())
            end
        end
    end
    for (a,b) in result
        @test a == b
    end

    HTTP.ConnectionPool.showpool(STDOUT)
    HTTP.ConnectionPool.closeall()

    result = []

    @sync begin
        for i = 1:min(num,100)
            @async try
                r = HTTP.request("GET",
                     "$http://httpbin.org/stream/$i"; config...)
                r = String(r.body)
                r = split(strip(r), "\n")
                push!(result, length(r) => i)
            catch e
                dump_async_exception(e, catch_stacktrace())
            end
        end
    end

    for (a,b) in result
        @test a == b
    end

    HTTP.ConnectionPool.showpool(STDOUT)
    HTTP.ConnectionPool.closeall()

    result = []

#=
    asyncmap(i->begin
        n = i % 20 + 1
        str = ""
        r = HTTP.open("GET", "$http://httpbin.org/stream/$n";
                      retries=5, config...) do s
            str = String(read(s))
        end
        l = split(strip(str), "\n")
        #println("GOT $i $n")

        push!(result, length(l) => n)

    end, 1:num, ntasks=20)

    for (a,b) in result
        @test a == b
    end

    result = []
=#

    @sync begin
        for i = 1:num
            n = i % 20 + 1
            @async try
                r = nothing
                str = nothing
                url = "$http://httpbin.org/stream/$n"
                if rand(Bool)
                    if rand(Bool)
                        for attempt in 1:4
                            try
                                #println("GET $i $n BufferStream $attempt")
                                s = BufferStream()
                                r = HTTP.request(
                                    "GET", url; response_stream=s, config...)
                                @assert r.status == 200
                                close(s)
                                str = String(read(s))
                                break
                            catch e
#                                st = catch_stacktrace()
                                if attempt == 10 ||
                                   !HTTP.RetryRequest.isrecoverable(e)
                                    rethrow(e)
                                end
                                buf = IOBuffer()
                                println(buf, "$i retry $e $attempt...")
                                #show(buf, "text/plain", st)
                                write(STDOUT, take!(buf))
                                sleep(0.1)
                            end
                        end
                    else
                        #println("GET $i $n Plain")
                        r = HTTP.request("GET", url; config...)
                        @assert r.status == 200
                        str = String(r.body)
                    end
                else
                    #println("GET $i $n open()")
                    r = HTTP.open("GET", url; config...) do http
                        str = String(read(http))
                    end
                    @assert r.status == 200
                end

                l = split(strip(str), "\n")
                #println("GOT $i $n $(length(l))")
                if length(l) != n
                    @show r
                    @show str
                end
                push!(result, length(l) => n)
            catch e
                push!(result, e => n)
                dump_async_exception(e, catch_stacktrace())
            end
        end
    end

    for (a,b) in result
        @test a == b
    end

    HTTP.ConnectionPool.showpool(STDOUT)
    HTTP.ConnectionPool.closeall()

end # testset

sleep(12)
