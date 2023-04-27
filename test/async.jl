module test_async

import ..httpbin
using Test, HTTP, JSON

@time @testset "ASync" begin
    configs = [
        Pair{Symbol, Any}[:verbose => 0],
        Pair{Symbol, Any}[:verbose => 0, :reuse_limit => 200],
        Pair{Symbol, Any}[:verbose => 0, :reuse_limit => 50]
    ]

    dump_async_exception(e, st) = @error "async exception: " exception=(e, st)

    @testset "HTTP.request - Headers - $config - https" for config in configs
        result = []

        @sync begin
            for i = 1:100
                @async try
                    response = HTTP.request("GET", "https://$httpbin/headers", ["i" => i]; config...)
                    response = JSON.parse(String(response.body))
                    push!(result, response["headers"]["I"] => [string(i)])
                catch e
                    dump_async_exception(e, stacktrace(catch_backtrace()))
                    rethrow(e)
                end
            end
        end

        for(a, b) in result
            @test a == b
        end

        HTTP.Connections.closeall()
    end

    @testset "HTTP.request - Body - $config - https" for config in configs
        result = []

        @sync begin
            for i=1:100
                @async try
                    response = HTTP.request("GET", "https://$httpbin/stream/$i"; config...)
                    response = String(response.body)
                    response = split(strip(response), "\n")
                    push!(result, length(response) => i)
                catch e
                    dump_async_exception(e, stacktrace(catch_backtrace()))
                    rethrow(e)
                end
            end
        end

        for (a, b) in result
            @test a == b
        end

        HTTP.Connections.closeall()
    end

    @testset "HTTP.open - $config - https" for config in configs
        result = []

        @sync begin
            for i=1:100
                @async try
                    open_response = nothing
                    url = "https://$httpbin/stream/$i"

                    response = HTTP.open("GET", url; config...) do http
                        open_response = String(read(http))
                    end

                    open_response = split(strip(open_response), "\n")
                    push!(result, length(open_response) => i)
                catch e
                    dump_async_exception(e, stacktrace(catch_backtrace()))
                    rethrow(e)
                end
            end
        end

        for (a, b) in result
            @test a == b
        end

        HTTP.Connections.closeall()
    end

    @testset "HTTP.request - Response Stream - $config - https" for config in configs
        result = []

        @sync begin
            for i=1:100
                @async try
                    stream_response = nothing

                    # Note: url for $i will give back $i responses split on "\n"
                    url = "https://$httpbin/stream/$i"

                    try
                        stream = Base.BufferStream()
                        response = HTTP.request("GET", url; response_stream=stream, config...)
                        close(stream)

                        stream_response = String(read(stream))
                        stream_response = split(strip(stream_response), "\n")
                        if length(stream_response) != i
                            @show join(stream_response, "\n")
                        end
                        push!(result, length(stream_response) => i)
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

        for (a, b) in result
            @test a == b
        end

        HTTP.Connections.closeall()
    end
end

end # module
