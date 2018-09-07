using Test
using HTTP
using HTTP.Base64
using HTTP.Sockets
using JSON
using MbedTLS: digest, MD_MD5, MD_SHA256

using HTTP.IOExtras
using HTTP: request


println("async tests")

stop_pool_dump = false

@async HTTP.listen() do http
    @show HTTP.Sockets.getsockname(http)
    startwrite(http)
    write(http, """
        <html><head>
            <title>HTTP.jl Connection Pool</title>
            <meta http-equiv="refresh" content="1">
            <style type="text/css" media="screen">
                td { padding-left: 5px; padding-right: 5px }
            </style>
        </head>
        <body><pre>
    """)
    write(http, "<body><pre>")
    buf = IOBuffer()
    HTTP.ConnectionPool.showpoolhtml(buf)
    write(http, take!(buf))
    write(http, "</pre></body>")
end

@async begin
    sleep(5)
    try
        run(`open http://localhost:8081`)
    catch e
        while !stop_pool_dump
            HTTP.ConnectionPool.showpool(stdout)
            sleep(1)
        end
    end
end

# Tiny S3 interface...
s3region = "ap-southeast-2"
s3url = "https://s3.$s3region.amazonaws.com"
#s3(method, path, body=UInt8[]; kw...) =
#    request(method, "$s3url/$path", [], body; aws_authorization=true, kw...)
#s3get(path; kw...) = s3("GET", path; kw...)
#s3put(path, data; kw...) = s3("PUT", path, data; kw...)

#=
function create_bucket(bucket)
    s3put(bucket, """
        <CreateBucketConfiguration
                     xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <LocationConstraint>$s3region</LocationConstraint>
        </CreateBucketConfiguration>""",
        statusexception=false)
end

create_bucket("http.jl.test")
=#

function dump_async_exception(e, st)
    buf = IOBuffer()
    write(buf, "==========\n@async exception:\n==========\n")
    show(buf, "text/plain", e)
    show(buf, "text/plain", st)
    write(buf, "==========\n\n")
    print(String(take!(buf)))
end

if haskey(ENV, "AWS_ACCESS_KEY_ID") || haskey(ENV, "AWS_DEFAULT_PROFILE")
@testset "async s3 dup$dup, count$count, sz$sz, pipw$pipe, $http, $mode" for
    count in [10, 100, 1000],
    dup in [0, 7],
    http in ["http", "https"],
    sz in [100, 10000],
    mode in [:request, :open],
    pipe in [0, 32]

if (dup == 0 || pipe == 0) && count > 100
    continue
end

global s3url
s3url = "$http://s3.$s3region.amazonaws.com"
println("running async s3 dup$dup, count$count, sz$sz, pipe$pipe, $http, $mode")

put_data_sums = Dict()
ch = 100
conf = [:reuse_limit => 90,
        :verbose => 0,
        :pipeline_limit => pipe,
        :connection_limit => dup + 1,
        :readtimeout => 120]

@sync for i = 1:count
    data = rand(UInt8(65):UInt8(75), sz)
    md5 = bytes2hex(digest(MD_MD5, data))
    put_data_sums[i] = md5
    @async try
        url = "$s3url/http.jl.test/file$i"
        r = nothing
        if mode == :open
            r = HTTP.open("PUT", url, ["Content-Length" => sz];
                    body_sha256=digest(MD_SHA256, data),
                    body_md5=digest(MD_MD5, data),
                    aws_authorization=true,
                    conf...) do http
                for n = 1:ch:sz
                    write(http, data[n:n+(ch-1)])
                    sleep(rand(1:10)/1000)
                end
            end
        end
        if mode == :request
            r = HTTP.request("PUT", url, [], data;
                    aws_authorization=true, conf...)
        end
        #println("S3 put file$i")
        @assert strip(HTTP.header(r, "ETag"), '"') == md5
    catch e
        dump_async_exception(e, stacktrace(catch_backtrace()))
        rethrow(e)
    end
end


get_data_sums = Dict()
@sync begin
    for i = 1:count
        @async try
            url = "$s3url/http.jl.test/file$i"
            buf = Base.BufferStream()
            r = nothing
            if mode == :open
                r = HTTP.open("GET", url, ["Content-Length" => 0];
                              aws_authorization=true,
                              conf...) do http
                    buf = Base.BufferStream() # in case of retry!
                    while !eof(http)
                        write(buf, readavailable(http))
                        sleep(rand(1:10)/1000)
                    end
                    close(buf)
                end
            end
            if mode == :request
                r = HTTP.request("GET", url; response_stream=buf,
                                             aws_authorization=true, conf...)
            end
            #println("S3 get file$i")
            bytes = read(buf)
            md5 = bytes2hex(digest(MD_MD5, bytes))
            get_data_sums[i] = (md5, strip(HTTP.header(r, "ETag"), '"'))
        catch e
            dump_async_exception(e, stacktrace(catch_backtrace()))
            rethrow(e)
        end
    end
end

for i = 1:count
    a, b = get_data_sums[i]
    @test a == b
    @test a == put_data_sums[i]
end

if !haskey(ENV, "HTTP_JL_TEST_LONG_ASYNC")
    break
end

end # testset
end # if haskey(ENV, "AWS_ACCESS_KEY_ID")

configs = [
    [:verbose => 0],
    [:verbose => 0, :reuse_limit => 200],
    [:verbose => 0, :reuse_limit => 50]
]


@testset "async $count, $num, $config, $http" for count in 1:1,
                                            num in [100, 1000, 2000],
                                            config in configs,
                                            http in ["http", "https"]

println("running async $count, 1:$num, $config, $http A")

    result = []
    @sync begin
        for i = 1:min(num,100)
            @async try
                r = HTTP.request("GET",
                 "$http://httpbin.org/headers", ["i" => i]; config...)
                r = JSON.parse(String(r.body))
                push!(result, r["headers"]["I"] => string(i))
            catch e
                dump_async_exception(e, stacktrace(catch_backtrace()))
                rethrow(e)
            end
        end
    end
    for (a,b) in result
        @test a == b
    end

    HTTP.ConnectionPool.showpool(stdout)
    HTTP.ConnectionPool.closeall()

    result = []

println("running async $count, 1:$num, $config, $http B")

    @sync begin
        for i = 1:min(num,100)
            @async try
                r = HTTP.request("GET",
                     "$http://httpbin.org/stream/$i"; config...)
                r = String(r.body)
                r = split(strip(r), "\n")
                push!(result, length(r) => i)
            catch e
                dump_async_exception(e, stacktrace(catch_backtrace()))
                rethrow(e)
            end
        end
    end

    for (a,b) in result
        @test a == b
    end

    HTTP.ConnectionPool.showpool(stdout)
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

println("running async $count, 1:$num, $config, $http C")

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
                                #println("GET $i $n Base.BufferStream $attempt")
                                s = Base.BufferStream()
                                r = HTTP.request(
                                    "GET", url; response_stream=s, config...)
                                @assert r.status == 200
                                str = String(read(s))
                                break
                            catch e
                                if attempt == 10 ||
                                   !HTTP.RetryRequest.isrecoverable(e)
                                    rethrow(e)
                                end
                                buf = IOBuffer()
                                println(buf, "$i retry $e $attempt...")
                                write(stdout, take!(buf))
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
                dump_async_exception(e, stacktrace(catch_backtrace()))
                rethrow(e)
            end
        end
    end

    for (a,b) in result
        @test a == b
    end

    HTTP.ConnectionPool.showpool(stdout)
    HTTP.ConnectionPool.closeall()


    if !haskey(ENV, "HTTP_JL_TEST_LONG_ASYNC")
        break
    end

end # testset

stop_pool_dump=true

HTTP.ConnectionPool.showpool(stdout)

println("async tests done")
