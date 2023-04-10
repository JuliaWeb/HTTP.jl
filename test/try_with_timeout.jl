@testset "try_with_timeout $warmup" for warmup in [true, false]
    throwerrorexception() = throw(ErrorException("error as expected"))
    throwargumenterror() = throw(ArgumentError("unexpected error"))

    @testset "rethrow exceptions" begin
        t = @elapsed begin
            err = try
                HTTP.try_with_timeout(1) do
                    throwerrorexception()
                end
            catch e
                e
            end
            @test err.ex isa ErrorException
        end
        if !warmup
            @test t < 1
        end
    end

    @testset "TimeoutError is thrown" begin
        t = @elapsed begin
            err = try
                HTTP.try_with_timeout(1) do
                    sleep(5)
                    throwargumenterror()
                end
            catch e
                e
            end
            @test err isa HTTP.TimeoutError
        end
        if !warmup
            @test 1 < t < 2
        end
    end

    @testset "value is successfully returned under timeout" begin
        t = @elapsed begin
            ret = HTTP.try_with_timeout(5) do
                sleep(1)
                return 1
            end
        end
        @test ret == 1
        if !warmup
            @test 1 < t < 2
        end
    end
end
