include("../src/exceptions.jl")

using ..TestRequest

@testset "Stack - Layers Conversions" begin
    single_layer = Type{<:HTTP.Layer}[BasicAuthLayer]
    single_stack = Stack{BasicAuthLayer}(nothing)
    @test HTTP.layers2stack(single_layer) == single_stack
    @test HTTP.stack2layers(single_stack) == single_layer

    layers = Type{<:HTTP.Layer}[BasicAuthLayer, RetryLayer, DebugLayer]
    stack = Stack{BasicAuthLayer}(Stack{RetryLayer}(Stack{DebugLayer}(nothing)))
    @test HTTP.layers2stack(layers) == stack
    @test HTTP.stack2layers(stack) == layers
end

@testset "HTTP Stack Inserting" begin

    @testset "Insert - Beginning" begin
        layers = [TestLayer, RedirectLayer, BasicAuthLayer, MessageLayer, RetryLayer, ExceptionLayer, ConnectionPoolLayer, StreamLayer]
        expected = HTTP.layers2stack(layers)

        result = insert(stack(), 1, TestLayer)
        @test expected == result

        result = insert(stack(), RedirectLayer, TestLayer)
        @test expected == result
    end

    @testset "Insert - Middle" begin
        layers = [RedirectLayer, BasicAuthLayer, MessageLayer, RetryLayer, TestLayer, ExceptionLayer, ConnectionPoolLayer, StreamLayer]
        expected = HTTP.layers2stack(layers)
        result = insert(stack(), ExceptionLayer, TestLayer)

        @test expected == result
    end

    @testset "Insert - End" begin
        layers = [RedirectLayer, BasicAuthLayer, MessageLayer, RetryLayer, ExceptionLayer, ConnectionPoolLayer, StreamLayer, TestLayer]
        expected = HTTP.layers2stack(layers)
        test_stack = stack()
        result = insert(test_stack, length(test_stack) + 1, TestLayer)

        @test expected == result
    end

    @testset "Insert - Non-existant layer" begin
        @test_throws HTTP.LayerNotFoundException insert(stack(), AWS4AuthLayer, TestLayer)
    end

    @testset "Insert - Multiple Same layer" begin
        test_stack = insert(stack(), RetryLayer, ExceptionLayer)

        layers = [RedirectLayer, BasicAuthLayer, MessageLayer, TestLayer, ExceptionLayer, RetryLayer, ExceptionLayer, ConnectionPoolLayer, StreamLayer]
        expected = HTTP.layers2stack(layers)
        result = insert(test_stack, ExceptionLayer, TestLayer)

        @test expected == result
    end

    @testset "Inserted final layer runs handler" begin
        TestRequest.FLAG[] = false
        test_stack = stack()
        test_stack = insert(test_stack, length(test_stack) + 1, LastLayer)
        request(test_stack, "GET", "https://httpbin.org/anything")
        @test TestRequest.FLAG[]
    end

    @testset "Insert/remove default layers" begin
        @test HTTP.insert_before!([1, 2], 2, 3) == [1, 3, 2]
        top = HTTP.stacktype(stack())
        insert_default!(top, TestLayer)
        @test HTTP.stacktype(stack()) <: TestLayer
        remove_default!(top, TestLayer)
        @test HTTP.stacktype(stack()) <: top
        insert_default!(Union{}, TestLayer)
        remove_default!(Union{}, TestLayer)
    end
end
