using Test
using HTTP
using Reseau

const HT = HTTP

@testset "HTTP core headers" begin
    @test HT.canonical_header_key("content-type") == "Content-Type"
    @test HT.canonical_header_key("X-CUSTOM-HEADER") == "X-Custom-Header"
    @test HT.canonical_header_key("x-forwarded-for") == "X-Forwarded-For"
    headers = HT.Headers()
    HT.setheader(headers, "content-type", "application/json")
    HT.appendheader(headers, "x-forwarded-for", "127.0.0.1")
    HT.appendheader(headers, "x-forwarded-for", "127.0.0.2")
    @test HT.hasheader(headers, "Content-Type")
    @test HT.header(headers, "content-type") == "application/json"
    @test eltype(typeof(headers)) == Pair{String, String}
    @test length(headers) == 2
    @test headers[1] == ("Content-Type" => "application/json")
    @test headers[2] == ("X-Forwarded-For" => "127.0.0.1, 127.0.0.2")
    @test collect(headers) == [
        "Content-Type" => "application/json",
        "X-Forwarded-For" => "127.0.0.1, 127.0.0.2",
    ]
    @test HT.headers(headers, "x-forwarded-for") == ["127.0.0.1, 127.0.0.2"]
    copied = HT.headers(headers, "x-forwarded-for")
    push!(copied, "127.0.0.3")
    @test HT.headers(headers, "x-forwarded-for") == ["127.0.0.1, 127.0.0.2"]
    HT.defaultheader!(headers, "content-type" => "text/plain")
    @test HT.header(headers, "Content-Type") == "application/json"
    HT.setheader(headers, "x-forwarded-for", "127.0.0.9")
    @test HT.headers(headers, "x-forwarded-for") == ["127.0.0.9"]
    HT.removeheader(headers, "x-forwarded-for")
    @test !HT.hasheader(headers, "x-forwarded-for")

    duplicates = HT.Headers()
    push!(duplicates, "X-Test" => "one")
    push!(duplicates, "X-Test" => "two")
    HT.setheader(duplicates, "x-test", "zero")
    @test collect(duplicates) == ["X-Test" => "zero", "X-Test" => "two"]

    empty_value = HT.Headers(["X-Empty" => ""])
    @test HT.header(empty_value, "X-Empty") == ""
    @test !HT.hasheader(empty_value, "X-Empty")
end

@testset "HTTP core header tokens" begin
    headers = HT.Headers()
    HT.setheader(headers, "Connection", "keep-alive, Upgrade")
    HT.appendheader(headers, "Connection", " close")
    @test HT.headercontains(headers, "connection", "upgrade")
    @test HT.headercontains(headers, "connection", "keep-alive")
    @test HT.headercontains(headers, "connection", "close")
    @test HT.headercontains(headers, "connection", "  UPGRADE\t")
    @test !HT.headercontains(headers, "connection", "te")
end

@testset "HTTP core request context" begin
    ctx = HT.RequestContext()
    @test !HT.canceled(ctx)
    @test !HT.expired(ctx)
    @test !haskey(ctx, :route)
    @test get(ctx, :route, nothing) === nothing
    ctx[:route] = "/health"
    ctx[:params] = Dict("id" => "7")
    @test haskey(ctx, :route)
    @test ctx[:route] == "/health"
    @test get(ctx, :params, nothing) == Dict("id" => "7")
    @test get(() -> "fallback", ctx, :missing) == "fallback"
    empty!(ctx)
    @test !haskey(ctx, :route)
    HT.set_deadline!(ctx, time_ns() + 50_000_000)
    @test !HT.expired(ctx)
    HT.set_deadline!(ctx, 1)
    @test HT.expired(ctx)
    HT.cancel!(ctx; message = "manual")
    @test HT.canceled(ctx)
end

@testset "HTTP core bodies" begin
    body = HT.BytesBody(UInt8[0x41, 0x42, 0x43])
    dst = Vector{UInt8}(undef, 2)
    n = HT.body_read!(body, dst)
    @test n == 2
    @test dst == UInt8[0x41, 0x42]
    n = HT.body_read!(body, dst)
    @test n == 1
    @test dst[1] == 0x43
    n = HT.body_read!(body, dst)
    @test n == 0
    HT.body_close!(body)
    @test HT.body_closed(body)
    cb_closed = Ref(false)
    cb_reads = Ref(0)
    cb = HT.CallbackBody(
        dst_buf -> begin
            cb_reads[] += 1
            isempty(dst_buf) && return 0
            dst_buf[1] = 0x5a
            return 1
        end,
        () -> begin
            cb_closed[] = true
            return nothing
        end,
    )
    cb_buf = Vector{UInt8}(undef, 1)
    @test HT.body_read!(cb, cb_buf) == 1
    @test cb_buf[1] == 0x5a
    HT.body_close!(cb)
    HT.body_close!(cb)
    @test HT.body_closed(cb)
    @test cb_closed[]
    @test cb_reads[] == 1
end

@testset "HTTP core request/response construction" begin
    headers = HT.Headers()
    HT.setheader(headers, "content-type", "text/plain")
    req = HT.Request("POST", "/upload"; headers = headers, content_length = 4, host = "localhost")
    res = HT.Response(201; reason = "Created", headers = headers, request = req)
    HT.defaultheader!(req, "Accept" => "*/*")
    @test req.method == "POST"
    @test req.target == "/upload"
    @test req.content_length == 4
    @test req.host == "localhost"
    @test HT.header(req.headers, "content-type") == "text/plain"
    @test req["Accept"] == "*/*"
    @test res.status == 201
    @test res.reason == "Created"
    @test res.request === req
    HT.setheader(headers, "content-type", "application/json")
    @test HT.header(req.headers, "content-type") == "text/plain"
    @test HT.header(res.headers, "content-type") == "text/plain"
end
