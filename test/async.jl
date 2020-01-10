using MbedTLS: digest, MD_SHA256, MD_MD5

@testset "ASync" begin
    s3region="ap-southeast-2"
    s3url="https://s3.$s3region.amazonaws.com"
    stop_pool_dump=false
    configs = [
        [:verbose => 0],
        [:verbose => 0, :reuse_limit => 200],
        [:verbose => 0, :reuse_limit => 50]
    ]
    protocols = ["http", "https"]

    function dump_async_exception(e, st)
        buf = IOBuffer()
        write(buf, "==========\n@async exception:\n==========\n")
        show(buf, "text/plain", e)
        show(buf, "text/plain", st)
        write(buf, "==========\n\n")
        print(String(take!(buf)))
    end

    function startASyncHTTP()
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
    end

    startASyncHTTP()

    @testset "AWS" begin
        if haskey(ENV, "AWS_ACCESS_KEY_ID") || haskey(ENV, "AWS_DEFAULT_PROFILE")
            @testset "async s3 dup$dup, count$count, sz$sz, pipe$pipe, $protocol, $mode" for
                count in [10, 100, 1000],
                dup in [0, 7],
                protocol in protocols,
                sz in [100, 10000],
                mode in [:request, :open],
                pipe in [0, 32]

                if (dup == 0 || pipe == 0) && count > 100
                    continue
                end # if

                println("running async s3 dup$dup, count$count, sz$sz, pipe$pipe, $protocol, $mode")
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
                                end  # for
                            end  # http open
                        end # if
                        if mode == :request
                            r = HTTP.request("PUT", url, [], data;
                                    aws_authorization=true, conf...)
                        end # if
                        @test strip(HTTP.header(r, "ETag"), '"') == md5
                    catch e
                        dump_async_exception(e, stacktrace(catch_backtrace()))
                        rethrow(e)
                    end # try-catch
                end # sync

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
                                    end # while
                                    close(buf)
                                end # http open
                            end # if
                            if mode == :request
                                r = HTTP.request("GET", url; response_stream=buf,
                                                             aws_authorization=true, conf...)
                            end # if
                            bytes = read(buf)
                            md5 = bytes2hex(digest(MD_MD5, bytes))
                            get_data_sums[i] = (md5, strip(HTTP.header(r, "ETag"), '"'))
                        catch e
                            dump_async_exception(e, stacktrace(catch_backtrace()))
                            rethrow(e)
                        end # try-catch
                    end # for
                end # sync

                for i = 1:count
                    a, b = get_data_sums[i]
                    @test a == b
                    @test a == put_data_sums[i]
                end # for

                if !haskey(ENV, "HTTP_JL_TEST_LONG_ASYNC")
                    break
                end # if
            end # testset
        end # if haskey(ENV, "AWS_ACCESS_KEY_ID")
    end

    @testset "HTTP.request - Headers - $config - $protocol" for config in configs, protocol in protocols
        result = []

        @sync begin
            for i = 1:100
                @async try
                    response = HTTP.request("GET", "$protocol://httpbin.org/headers", ["i" => i]; config...)
                    response = JSON.parse(String(response.body))
                    push!(result, response["headers"]["I"] => string(i))
                catch e
                    dump_async_exception(e, stacktrace(catch_backtrace()))
                    rethrow(e)
                end
            end
        end

        for(a, b) in result
            @test a == b
        end

        HTTP.ConnectionPool.closeall()
    end

    @testset "HTTP.request - Body - $config - $protocol" for config in configs, protocol in protocols
        result = []

        @sync begin
            for i=1:100
                @async try
                    response = HTTP.request("GET", "$protocol://httpbin.org/stream/$i"; config...)
                    response = String(response.body)
                    response = split(strip(response), "\n")
                    push!(result, length(response) => i)
                catch e
                    dump_async_exception(e, stacktrace(catch_backtrace()))
                    rethrow(e)
                end
            end
        end

        for (a,b) in result
            @test a == b
        end

        HTTP.ConnectionPool.closeall()
    end

    @testset "HTTP.open - $config - $protocol" for config in configs, protocol in protocols
        result = []

        @sync begin
            for i=1:100
                @async try
                    open_response = nothing
                    url = "$protocol://httpbin.org/stream/$i"

                    response = HTTP.open("GET", url; config...) do http
                        open_response = String(read(http))
                    end

                    @test response.status == 200

                    open_response = split(strip(open_response), "\n")
                    push!(result, length(open_response) => i)
                catch e
                    dump_async_exception(e, stacktrace(catch_backtrace()))
                    rethrow(e)
                end
            end
        end

        for (a,b) in result
            @test a == b
        end

        HTTP.ConnectionPool.closeall()
    end

    @testset "HTTP.request - Response Stream - $config - $protocol" for config in configs, protocol in protocols
        result = []

        @sync begin
            for i=1:100
                @async try
                    stream_response = nothing

                    # Note: url for $i will give back $i responses split on "\n"
                    url = "$protocol://httpbin.org/stream/$i"

                    try
                        stream = Base.BufferStream()
                        response = HTTP.request("GET", url; response_stream=stream, config...)

                        @test response.status == 200
                        stream_response = String(read(stream))
                    catch e
                        if !HTTP.RetryRequest.isrecoverable(e)
                            rethrow(e)
                        end
                    end

                    stream_response = split(strip(stream_response), "\n")
                    push!(result, length(stream_response) => i)
                catch e
                    dump_async_exception(e, stacktrace(catch_backtrace()))
                    rethrow(e)
                end
            end
        end

        for (a,b) in result
            @test a == b
        end

        HTTP.ConnectionPool.closeall()
    end

    stop_pool_dump = true  # Kill the HTTP server
end