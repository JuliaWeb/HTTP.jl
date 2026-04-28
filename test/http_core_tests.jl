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
    push!(duplicates, "X-Other" => "keep")
    push!(duplicates, "X-Test" => "two")
    HT.setheader(duplicates, "x-test", "zero")
    @test collect(duplicates) == ["X-Test" => "zero", "X-Other" => "keep"]

    remove_all = HT.Headers()
    push!(remove_all, "X-Test" => "one")
    push!(remove_all, "X-Other" => "keep")
    push!(remove_all, "X-Test" => "two")
    HT.removeheader(remove_all, "x-test")
    @test collect(remove_all) == ["X-Other" => "keep"]

    empty_value = HT.Headers(["X-Empty" => ""])
    @test HT.header(empty_value, "X-Empty") == ""
    @test !HT.hasheader(empty_value, "X-Empty")
end

@testset "HTTP core header tokens" begin
    headers = HT.Headers()
    HT.setheader(headers, "Connection", "keep-alive, Upgrade")
    push!(headers, "X-Other" => "keep")
    push!(headers, "Connection" => " close")
    @test HT.headercontains(headers, "connection", "upgrade")
    @test HT.headercontains(headers, "connection", "keep-alive")
    @test HT.headercontains(headers, "connection", "close")
    @test HT.headercontains(headers, "connection", "  UPGRADE\t")
    @test !HT.headercontains(headers, "connection", "te")

    exact = HT.Headers()
    push!(exact, "Connection" => "keep-alive")
    push!(exact, "X-Other" => "keep")
    push!(exact, "Connection" => "close")
    @test HT.hasheader(exact, "connection", "close")
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

    compat_req = HT.Request(
        "PUT",
        "/compat",
        ["X-Test" => "1"],
        "body";
        version=v"1.0",
        context=Dict(:route => "/compat"),
    )
    @test compat_req.version == v"1.0.0"
    @test compat_req.context[:route] == "/compat"
    @test HT.get_request_context(compat_req) isa HT.RequestContext
    @test HT.get_request_context(compat_req) !== compat_req.context
    @test compat_req.body isa HT.BytesBody
    @test compat_req.content_length == 4

    compat_res = HT.Response(202, ["X-Reply" => "yes"], "ok"; version=v"1.0", request=compat_req)
    @test compat_res.version == v"1.0.0"
    @test compat_res.status_code == 202
    @test HT.header(compat_res.headers, "X-Reply") == "yes"
    @test compat_res.request === compat_req
    @test compat_res.body isa HT.BytesBody
    @test compat_res.content_length == 2

    keyword_body_res = HT.Response(200; headers=["X-Body" => "keyword"], body="ok")
    @test keyword_body_res.status == 200
    @test HT.header(keyword_body_res.headers, "X-Body") == "keyword"
    @test keyword_body_res.body isa HT.BytesBody
    @test keyword_body_res.content_length == 2

    keyword_empty_res = HT.Response(204; body=nothing)
    @test keyword_empty_res.status == 204
    @test keyword_empty_res.body isa HT.EmptyBody
end

@testset "HTTP core compatibility aliases" begin
    @test HT.TimeoutError === HT.HTTPTimeoutError
    @test HT.TimeoutError("read", Int64(1)) isa HT.HTTPError
    @test HT.escape("a b") == "a%20b"
end

@testset "HTTP core request/response display" begin
    request_headers = HT.Headers()
    HT.setheader(request_headers, "Authorization", "Bearer super-secret")
    HT.setheader(request_headers, "Content-Type", "text/plain")
    request = HT.Request(
        "POST",
        "/submit";
        headers=request_headers,
        body=HT.BytesBody(collect(codeunits("hello world"))),
        host="example.com",
        content_length=11,
    )

    compact = sprint(show, request)
    @test occursin("HTTP.Request POST example.com/submit", compact)
    @test occursin("2 headers", compact)
    @test occursin("11-byte body", compact)
    @test !occursin("super-secret", compact)

    plain = sprint(io -> show(io, MIME"text/plain"(), request))
    @test occursin("POST /submit HTTP/1.1", plain)
    @test occursin("Host: example.com", plain)
    @test occursin("Authorization: ******", plain)
    @test occursin("Content-Type: text/plain\r\n\r\nhello world", plain)
    @test occursin("hello world", plain)
    @test !occursin("super-secret", plain)

    compact_plain = sprint(io -> show(IOContext(io, :compact => true), MIME"text/plain"(), request))
    @test compact_plain == compact

    large_body = repeat("a", HT._DEFAULT_MESSAGE_SHOW_BODY_NBYTES + 5)
    limited_request = HT.Request(
        "POST",
        "/large";
        headers=HT.Headers(["Content-Type" => "text/plain"]),
        body=HT.BytesBody(collect(codeunits(large_body))),
        host="example.com",
        content_length=ncodeunits(large_body),
    )
    limited_plain = sprint(io -> show(io, MIME"text/plain"(), limited_request))
    @test occursin("[truncated after $(HT._DEFAULT_MESSAGE_SHOW_BODY_NBYTES) of $(ncodeunits(large_body)) bytes]", limited_plain)
    full_print = sprint(print, limited_request)
    @test !occursin("[truncated after", full_print)
    @test occursin(large_body, full_print)

    reads = Ref(0)
    callback_request = HT.Request(
        "POST",
        "/stream";
        body=HT.CallbackBody(
            dst -> begin
                reads[] += 1
                isempty(dst) && return 0
                dst[1] = UInt8('x')
                return 1
            end,
            () -> nothing,
        ),
        content_length=7,
    )
    callback_print = sprint(print, callback_request)
    @test occursin("<7-byte streaming body omitted>", callback_print)
    @test reads[] == 0

    compressed_headers = HT.Headers()
    HT.setheader(compressed_headers, "Content-Encoding", "gzip")
    compressed_response = HT.Response(
        200,
        UInt8[0x1f, 0x8b, 0x08, 0x00];
        headers=compressed_headers,
        content_length=4,
    )
    compressed_plain = sprint(io -> show(io, MIME"text/plain"(), compressed_response))
    @test occursin("<gzip-compressed 4-byte body omitted>", compressed_plain)

    response_headers = HT.Headers()
    HT.setheader(response_headers, "Set-Cookie", "session=secret")
    response = HT.Response(
        201,
        Vector{UInt8}(codeunits("created"));
        reason="Created",
        headers=response_headers,
        content_length=7,
    )
    response_compact = sprint(show, response)
    @test occursin("HTTP.Response 201 Created", response_compact)
    @test occursin("1 header", response_compact)
    response_plain = sprint(io -> show(io, MIME"text/plain"(), response))
    @test occursin("HTTP/1.1 201 Created", response_plain)
    @test occursin("Set-Cookie: ******", response_plain)
    @test occursin("Set-Cookie: ******\r\n\r\ncreated", response_plain)
    @test occursin("created", response_plain)
    @test !occursin("session=secret", response_plain)

    empty_request = HT.Request("GET", "/"; headers=HT.Headers(["Accept-Encoding" => "gzip, deflate"]), host="example.com", content_length=0)
    empty_request_plain = sprint(io -> show(io, MIME"text/plain"(), empty_request))
    @test !endswith(empty_request_plain, "\r\n")
    @test !endswith(empty_request_plain, "\n")

    empty_response = HT.Response(204; headers=HT.Headers(["Connection" => "close"]), content_length=0)
    empty_response_plain = sprint(io -> show(io, MIME"text/plain"(), empty_response))
    @test !endswith(empty_response_plain, "\r\n")
    @test !endswith(empty_response_plain, "\n")
end
