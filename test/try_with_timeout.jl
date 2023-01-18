@testitem "try_with_timeout" begin

@testset "try_with_timeout warmup=$warmup" for warmup in [true, false]
    nevertimeout() = false
    timeoutafterfirstdelay() = true
    throwerrorexception() = throw(ErrorException("error as expected"))
    throwargumenterror() = throw(ArgumentError("unexpected error"))

    @testset "rethrow exceptions" begin
        t = @elapsed begin
            @test_throws ErrorException HTTP.try_with_timeout(nevertimeout, 1) do
                throwerrorexception()
            end
        end
        if !warmup
            @test t < 1
        end
    end

    @testset "rethrow exceptions from shouldtimeout callback" begin
        t = @elapsed begin
            @test_throws ErrorException HTTP.try_with_timeout(throwerrorexception, 1) do
                sleep(5)
                throwargumenterror()
            end
        end
        if !warmup
            @test 1 < t < 2
        end
    end

    @testset "rethrow exceptions from iftimeout callback" begin
        t = @elapsed begin
            @test_throws ErrorException HTTP.try_with_timeout(timeoutafterfirstdelay, 1, throwerrorexception) do
                sleep(5)
                throwargumenterror()
            end
        end
        if !warmup
            @test 1 < t < 2
        end
    end
end

end # testitem
