module test_async

using Test, HTTP, JSON

@time @testset "ASync" begin
    configs = [
        Pair{Symbol, Any}[:verbose => 0, :status_exception => false],
        Pair{Symbol, Any}[:verbose => 0, :status_exception => false, :reuse_limit => 200],
        Pair{Symbol, Any}[:verbose => 0, :status_exception => false, :reuse_limit => 50]
    ]
    protocols = ["http", "https"]

    dump_async_exception(e, st) = @error "async exception: " exception=(e, st)

    @testset "HTTP.request - Headers - $config - $protocol" for config in configs, protocol in protocols
        result = []

        @sync begin
            for i = 1:100
                @async try
                    response = HTTP.request("GET", "$protocol://httpbin.org/headers", ["i" => i]; config...)
                    if response.status != 200
                        @error "non-200 response" response=response
                    else
                        response = JSON.parse(String(response.body))
                        push!(result, response["headers"]["I"] => string(i))
                    end
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
                    if response.status != 200
                        @error "non-200 response" response=response
                    else
                        response = String(response.body)
                        response = split(strip(response), "\n")
                        push!(result, length(response) => i)
                    end
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

                    if response.status != 200
                        @error "non-200 response" response=response
                    else
                        open_response = split(strip(open_response), "\n")
                        push!(result, length(open_response) => i)
                    end
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

                        if response.status != 200
                            @error "non-200 response" response=response
                        else
                            stream_response = String(read(stream))
                            stream_response = split(strip(stream_response), "\n")
                            if length(stream_response) != i
                                @show join(stream_response, "\n")
                            end
                            push!(result, length(stream_response) => i)
                        end
                    catch e
                        if !HTTP.RetryRequest.isrecoverable(e)
                            rethrow(e)
                        end
                    end
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
end

end # module
