using Test
using HTTP
using Reseau

const HT = HTTP

@testset "HTTP core headers" begin
    @test HT.canonical_header_key("content-type") == "Content-Type"
    @test HT.canonical_header_key("X-CUSTOM-HEADER") == "X-Custom-Header"
    @test HT.canonical_header_key("x-forwarded-for") == "X-Forwarded-For"
    @test HT.canonical_header_key("accept-query") == "Accept-Query"
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

    headers = HT.Headers(var"content-type" = "application/json")
    @test headers == HTTP.Headers(["Content-Type" => "application/json"])
    headers["content-type"] = "replaced"
    @test headers["Content-Type"] == "replaced"

    headers2 = HT.Headers(:a => "a", b = "b")
    @test headers2 == HT.Headers(["A" => "a", "B" => "b"])

    merge!(headers, headers2)
    @test headers == HTTP.Headers(["Content-Type" => "replaced", "A" => "a", "B" => "b"])

    # overlapping key: append! uses replace semantics — no duplicate entries
    headers3 = HT.Headers(["Content-Type" => "text/plain", "X-Keep" => "yes"])
    merge!(headers3, HT.Headers(["Content-Type" => "application/json", "X-New" => "1"]))
    @test headers3["Content-Type"] == "application/json"  # replaced, not duplicated
    @test headers3["X-Keep"] == "yes"                     # preserved
    @test headers3["X-New"] == "1"                        # added
    @test length(collect(headers3)) == 3                   # exactly 3 entries, no duplicate

    # Set-Cookie is exempt: each entry is a distinct cookie, never overwritten
    headers4 = HT.Headers(["Set-Cookie" => "a=1", "X-Other" => "v"])
    merge!(headers4, HT.Headers(["Set-Cookie" => "b=2", "X-Other" => "w"]))
    cookies = [v for (k, v) in collect(headers4) if k == "Set-Cookie"]
    @test length(cookies) == 2          # both cookies preserved
    @test "a=1" in cookies
    @test "b=2" in cookies
    @test headers4["X-Other"] == "w"   # non-cookie header replaced
    @test length(collect(headers4)) == 3  # Set-Cookie×2 + X-Other×1

    # append! uses appendheader semantics: comma-merges when last entry has same key
    headers5 = HT.Headers(["Accept" => "text/html"])
    append!(headers5, HT.Headers(["Accept" => "application/json"]))
    @test headers5["Accept"] == "text/html, application/json"  # comma-merged
    @test length(collect(headers5)) == 1  # merged into single entry
    # non-adjacent same key: pushed as new entry (appendheader only merges the last entry)
    headers5b = HT.Headers(["Accept" => "text/html", "X-Tag" => "v"])
    append!(headers5b, HT.Headers(["Accept" => "application/json"]))
    @test length([v for (k, v) in collect(headers5b) if k == "Accept"]) == 2  # not merged
    # Set-Cookie via append! is always pushed (never merged)
    headers6 = HT.Headers(["Set-Cookie" => "x=1"])
    append!(headers6, HT.Headers(["Set-Cookie" => "y=2"]))
    @test length([v for (k, v) in collect(headers6) if k == "Set-Cookie"]) == 2
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
    @test length(body) == 3
    @test !isempty(body)
    @test body[1] == 0x41
    @test body[3] == 0x43
    @test collect(body) == UInt8[0x41, 0x42, 0x43]
    @test copy(body) == UInt8[0x41, 0x42, 0x43]
    @test convert(Vector{UInt8}, body) == UInt8[0x41, 0x42, 0x43]
    @test Array(body) == UInt8[0x41, 0x42, 0x43]
    @test Vector{UInt8}(body) == UInt8[0x41, 0x42, 0x43]
    dst = Vector{UInt8}(undef, 2)
    n = HT.body_read!(body, dst)
    @test n == 2
    @test dst == UInt8[0x41, 0x42]
    @test length(body) == 1
    @test collect(body) == UInt8[0x43]
    n = HT.body_read!(body, dst)
    @test n == 1
    @test dst[1] == 0x43
    n = HT.body_read!(body, dst)
    @test n == 0
    @test isempty(body)
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

@testset "HTTP core trim narrowing contracts" begin
    text = "text"
    substring = SubString(text, 2, 3)
    bytes = UInt8[0x61]
    bytes_body = HT.BytesBody(copy(bytes))
    codeunits_body = HT.BytesBody(codeunits(text))
    unknown_body = Ref(1)

    for body in (
        nothing,
        text,
        substring,
        bytes,
        HT.EmptyBody(),
        bytes_body,
        codeunits_body,
        unknown_body,
    )
        @test HT._with_body_narrowed(identity, body) === body
    end

    @test HT._response_body_known_empty(nothing)
    @test HT._response_body_known_empty(HT.EmptyBody())
    @test HT._response_body_known_empty("")
    @test !HT._response_body_known_empty("x")

    response_for = body -> HT.Response{typeof(body)}(
        200,
        "",
        HT.Headers(),
        HT.Headers(),
        body,
        Int64(0),
        UInt8(1),
        UInt8(1),
        false,
        nothing,
        nothing,
        nothing,
        0,
    )
    for body in (
        text,
        substring,
        bytes,
        nothing,
        HT.EmptyBody(),
        bytes_body,
        codeunits_body,
        unknown_body,
    )
        response = response_for(body)
        @test HT._with_response_narrowed(identity, response) === response
    end
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

    bytes = UInt8[0x00, 0x01]
    byte_res = HT.Response(200, bytes)
    @test byte_res.body === bytes
    @test byte_res.body[1] == 0x00
    @test collect(byte_res.body) == bytes
    @test byte_res.content_length == 2

    keyword_byte_res = HT.Response(200; body=bytes)
    @test keyword_byte_res.body === bytes
    @test keyword_byte_res.content_length == 2

    compat_byte_res = HT.Response(200, ["Content-Type" => "application/octet-stream"], bytes)
    @test compat_byte_res.body === bytes
    @test compat_byte_res.content_length == 2
end

@testset "HTTP core compatibility aliases" begin
    @test HT.TimeoutError === HT.HTTPTimeoutError
    # Two-arg constructor (legacy compatibility) defaults elapsed_ns to 0.
    legacy = HT.TimeoutError("read", Int64(1))
    @test legacy isa HT.HTTPError
    @test legacy.operation == "read"
    @test legacy.timeout_ns == 1
    @test legacy.elapsed_ns == 0
    @test HT.escape("a b") == "a%20b"
end

@testset "HTTP core transport error wrappers" begin
    # New error types are subtypes of HTTPError so callers can pattern-match
    # on `e isa HTTP.HTTPError` without depending on Reseau internals.
    @test HT.ConnectError <: HT.HTTPError
    @test HT.DNSError <: HT.HTTPError
    @test HT.TLSHandshakeError <: HT.HTTPError
    @test HT.AddressInUseError <: HT.HTTPError

    addr = "127.0.0.1:1"
    cause = ErrorException("boom")
    @test HT.ConnectError(addr, cause).address == addr
    @test HT.ConnectError(addr, cause).cause === cause
    @test HT.DNSError("host.invalid", cause).hostname == "host.invalid"
    @test HT.AddressInUseError(addr).address == addr

    # TimeoutError carries operation, timeout_ns, and elapsed_ns.
    err = HT.TimeoutError("connect", Int64(2_000_000_000), Int64(1_999_000_000))
    @test err.operation == "connect"
    @test err.timeout_ns == 2_000_000_000
    @test err.elapsed_ns == 1_999_000_000
    msg = sprint(showerror, err)
    @test occursin("connect", msg)
    @test occursin("budget", msg)
    @test occursin("elapsed", msg)
end

@testset "HTTP core headers display" begin
    headers = HT.Headers([
        "Authorization" => "Bearer super-secret",
        "Proxy-Authorization" => "Basic dXNlcjpwYXNz",
        "Cookie" => "session=secret-cookie",
        "Set-Cookie" => "id=secret-id",
        "Content-Type" => "text/plain",
    ])

    # Sensitive header values must be masked in both the compact (2-arg) and
    # text/plain (3-arg) show forms, so they never leak into stacktraces,
    # logging output, or the REPL.
    compact = sprint(show, headers)
    @test occursin("HTTP.Headers([", compact)
    @test occursin("\"Authorization\" => \"******\"", compact)
    @test occursin("\"Proxy-Authorization\" => \"******\"", compact)
    @test occursin("\"Cookie\" => \"******\"", compact)
    @test occursin("\"Set-Cookie\" => \"******\"", compact)
    @test occursin("\"Content-Type\" => \"text/plain\"", compact)
    @test !occursin("secret", compact)
    @test !occursin("dXNlcjpwYXNz", compact)

    plain = sprint(io -> show(io, MIME"text/plain"(), headers))
    @test occursin("5-element", plain)
    @test occursin("\"Authorization\" => \"******\"", plain)
    @test occursin("\"Proxy-Authorization\" => \"******\"", plain)
    @test occursin("\"Cookie\" => \"******\"", plain)
    @test occursin("\"Set-Cookie\" => \"******\"", plain)
    @test occursin("\"Content-Type\" => \"text/plain\"", plain)
    @test !occursin("secret", plain)
    @test !occursin("dXNlcjpwYXNz", plain)

    # Redaction is case-insensitive.
    lower = HT.Headers()
    push!(lower.entries, "authorization" => "Bearer raw-secret")
    @test occursin("\"authorization\" => \"******\"", sprint(show, lower))
    @test !occursin("raw-secret", sprint(io -> show(io, MIME"text/plain"(), lower)))

    # Redaction is display-only; programmatic access returns the real value.
    @test HT.header(headers, "Authorization") == "Bearer super-secret"

    # Empty collections render without a trailing colon or entries.
    @test sprint(show, HT.Headers()) == "HTTP.Headers([])"
    @test endswith(sprint(io -> show(io, MIME"text/plain"(), HT.Headers())), "0-element HTTP.Headers")
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

    hostile_response = HT.Response(
        200,
        Vector{UInt8}(codeunits("\e[31mred\nnext\a"));
        reason="\e]0;pwned\aOK",
        content_length=14,
    )
    hostile_compact = sprint(show, hostile_response)
    @test !occursin('\e', hostile_compact)
    @test !occursin('\a', hostile_compact)
    @test occursin("\\e]0;pwned\\x07OK", hostile_compact)
    hostile_plain = sprint(io -> show(io, MIME"text/plain"(), hostile_response))
    @test !occursin('\e', hostile_plain)
    @test !occursin('\a', hostile_plain)
    @test occursin("HTTP/1.1 200 \\e]0;pwned\\x07OK", hostile_plain)
    @test occursin("\\e[31mred\\nnext\\x07", hostile_plain)

    empty_request = HT.Request("GET", "/"; headers=HT.Headers(["Accept-Encoding" => "gzip, deflate"]), host="example.com", content_length=0)
    empty_request_plain = sprint(io -> show(io, MIME"text/plain"(), empty_request))
    @test !endswith(empty_request_plain, "\r\n")
    @test !endswith(empty_request_plain, "\n")

    empty_response = HT.Response(204; headers=HT.Headers(["Connection" => "close"]), content_length=0)
    empty_response_plain = sprint(io -> show(io, MIME"text/plain"(), empty_response))
    @test !endswith(empty_response_plain, "\r\n")
    @test !endswith(empty_response_plain, "\n")
end
