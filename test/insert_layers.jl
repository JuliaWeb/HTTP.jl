include("../src/exceptions.jl")

using ..TestRequest

@testset "HTTP Stack Inserting" begin
    @testset "Insert - Beginning" begin
        expected = TestLayer{RedirectLayer{BasicAuthLayer{MessageLayer{RetryLayer{ExceptionLayer{ConnectionPoolLayer{StreamLayer{Union{}}}}}}}}}
        result = insert(stack(), RedirectLayer, TestLayer)

        @test expected == result
    end

    @testset "Insert - Middle" begin
        expected = RedirectLayer{BasicAuthLayer{MessageLayer{RetryLayer{TestLayer{ExceptionLayer{ConnectionPoolLayer{StreamLayer{Union{}}}}}}}}}
        result = insert(stack(), ExceptionLayer, TestLayer)

        @test expected == result
    end

    @testset "Insert - End" begin
        expected = RedirectLayer{BasicAuthLayer{MessageLayer{RetryLayer{ExceptionLayer{ConnectionPoolLayer{StreamLayer{TestLayer{Union{}}}}}}}}}
        result = insert(stack(), Union{}, TestLayer)

        @test expected == result
    end

    @testset "Insert - Non-existant layer" begin
        @test_throws HTTP.Layers.LayerNotFoundException insert(stack(), AWS4AuthLayer, TestLayer)
    end

    @testset "Insert - Multiple Same layer" begin
        test_stack = insert(stack(), RetryLayer, ExceptionLayer)

        expected = RedirectLayer{BasicAuthLayer{MessageLayer{TestLayer{ExceptionLayer{RetryLayer{ExceptionLayer{ConnectionPoolLayer{StreamLayer{Union{}}}}}}}}}}
        result = insert(test_stack, ExceptionLayer, TestLayer)

        @test expected == result
    end

    @testset "Inserted final layer runs handler" begin
        TestRequest.FLAG[] = false
        request(insert(stack(), Union{}, LastLayer), "GET", "https://httpbin.org/anything")
        @test TestRequest.FLAG[]
    end
end
