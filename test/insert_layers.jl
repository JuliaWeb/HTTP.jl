include("../src/exceptions.jl")

using ..TestRequest

@testset "HTTP Stack Inserting" begin
    @testset "Insert - Beginning" begin
        expected = TestLayer{TopLayer{RedirectLayer{BasicAuthLayer{MessageLayer{RetryLayer{ExceptionLayer{ConnectionPoolLayer{StreamLayer{Union{}}}}}}}}}}
        result = insert(stack(), RedirectLayer, TestLayer)

        @test expected == result
    end

    @testset "Insert - Middle" begin
        expected = TopLayer{RedirectLayer{BasicAuthLayer{MessageLayer{RetryLayer{TestLayer{ExceptionLayer{ConnectionPoolLayer{StreamLayer{Union{}}}}}}}}}}
        result = insert(stack(), ExceptionLayer, TestLayer)

        @test expected == result
    end

    @testset "Insert - End" begin
        expected = TopLayer{RedirectLayer{BasicAuthLayer{MessageLayer{RetryLayer{ExceptionLayer{ConnectionPoolLayer{StreamLayer{TestLayer{Union{}}}}}}}}}}
        result = insert(stack(), Union{}, TestLayer)

        @test expected == result
    end

    @testset "Insert - Non-existant layer" begin
        @test_throws HTTP.Layers.LayerNotFoundException insert(stack(), AWS4AuthLayer, TestLayer)
    end

    @testset "Insert - Multiple Same layer" begin
        test_stack = insert(stack(), RetryLayer, ExceptionLayer)

        expected = TopLayer{RedirectLayer{BasicAuthLayer{MessageLayer{TestLayer{ExceptionLayer{RetryLayer{ExceptionLayer{ConnectionPoolLayer{StreamLayer{Union{}}}}}}}}}}}
        result = insert(test_stack, ExceptionLayer, TestLayer)

        @test expected == result
    end

    @testset "Inserted final layer runs handler" begin
        TestRequest.FLAG[] = false
        request(insert(stack(), Union{}, LastLayer), "GET", "https://httpbin.org/anything")
        @test TestRequest.FLAG[]
    end

    @testset "Insert/remove default layers" begin
        top = HTTP.top_layer(stack())
        insert_default!(top, TestLayer)
        @test HTTP.top_layer(stack()) <: TestLayer
        remove_default!(top, TestLayer)
        @test HTTP.top_layer(stack()) <: top
        insert_default!(Union{}, TestLayer)
        remove_default!(Union{}, TestLayer)
    end
end
