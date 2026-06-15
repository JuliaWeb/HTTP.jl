using Test
using HTTP

const W = HTTP.WebSockets

# ── codec-level: compress/decompress + negotiation (no sockets) ──────────────

@testset "permessage-deflate codec round-trips (RFC 7692)" begin
    ctx_takeover = W.PMCEParams(false, false, 15, 15)

    # raw round-trips across payload shapes, client compresses -> server inflates
    c = W.PMCEContext(ctx_takeover, true)
    s = W.PMCEContext(ctx_takeover, false)
    for msg in (Vector{UInt8}("Hello permessage-deflate!"), UInt8[], UInt8[0x00],
                Vector{UInt8}("☃ 日本語 🚀"), rand(UInt8, 5000), collect(0x00:0xff))
        comp = W.pmce_compress!(c, msg)
        @test W.pmce_decompress!(s, comp) == msg
    end
    # empty message is a single 0x00 byte on the wire (RFC 7692 §7.2.3.6)
    @test W.pmce_compress!(W.PMCEContext(ctx_takeover, true), UInt8[]) == UInt8[0x00]

    # context takeover: a repeated message compresses smaller the second time
    c2 = W.PMCEContext(ctx_takeover, true); s2 = W.PMCEContext(ctx_takeover, false)
    big = Vector{UInt8}(repeat("the quick brown fox ", 16))
    a = W.pmce_compress!(c2, big); @test W.pmce_decompress!(s2, a) == big
    b = W.pmce_compress!(c2, big); @test W.pmce_decompress!(s2, b) == big
    @test length(b) < length(a)

    # no_context_takeover: identical output each message (window reset)
    nct = W.PMCEParams(true, true, 15, 15)
    c3 = W.PMCEContext(nct, true); s3 = W.PMCEContext(nct, false)
    x = W.pmce_compress!(c3, big); @test W.pmce_decompress!(s3, x) == big
    y = W.pmce_compress!(c3, big); @test W.pmce_decompress!(s3, y) == big
    @test x == y

    # malformed compressed data is rejected
    @test_throws W.WebSocketProtocolError W.pmce_decompress!(
        W.PMCEContext(ctx_takeover, false), UInt8[0xde, 0xad, 0xbe, 0xef, 0x99])

    # decompression-bomb guard: a tiny compressed payload that inflates past the
    # cap throws rather than allocating unbounded memory
    bomb_src = zeros(UInt8, 1_000_000)
    bomb = W.pmce_compress!(W.PMCEContext(ctx_takeover, true), bomb_src)
    @test length(bomb) < 5000
    @test_throws W.WebSocketProtocolError W.pmce_decompress!(
        W.PMCEContext(ctx_takeover, false), bomb; max_size = 4096)
end

@testset "permessage-deflate extension negotiation" begin
    # default client offer is the browser-standard form
    @test W._pmce_client_offer_header() == "permessage-deflate; client_max_window_bits"

    # server accepts a plain offer
    neg = W._pmce_server_negotiate("permessage-deflate; client_max_window_bits")
    @test neg !== nothing
    params, resp = neg
    @test params isa W.PMCEParams
    @test W._pmce_client_accept(resp) isa W.PMCEParams

    # no_context_takeover requested both ways is honored + echoed
    n2, r2 = W._pmce_server_negotiate("permessage-deflate; client_no_context_takeover; server_no_context_takeover")
    @test n2.client_no_context_takeover && n2.server_no_context_takeover
    @test occursin("client_no_context_takeover", r2) && occursin("server_no_context_takeover", r2)

    # explicit window bits honored; window bits of 8 (unsupported by zlib) declined
    n3, r3 = W._pmce_server_negotiate("permessage-deflate; server_max_window_bits=10")
    @test n3.server_max_window_bits == 10 && occursin("server_max_window_bits=10", r3)
    @test W._pmce_server_negotiate("permessage-deflate; server_max_window_bits=8") === nothing

    # unknown parameters / non-pmce extensions are declined
    @test W._pmce_server_negotiate("permessage-deflate; bogus=1") === nothing
    @test W._pmce_server_negotiate("x-webkit-deflate-frame") === nothing
    @test W._pmce_server_negotiate(nothing) === nothing

    # disabled server never negotiates even when offered
    @test W._pmce_negotiate_for_request("permessage-deflate; client_max_window_bits", false) === nothing

    # client rejects a server response that includes an unknown parameter
    @test_throws W.WebSocketProtocolError W._pmce_client_accept("permessage-deflate; bogus_param=1")
    # client rejects a server enabling a different extension
    @test_throws W.WebSocketProtocolError W._pmce_client_accept("x-some-other-extension")
    # no response header -> no compression
    @test W._pmce_client_accept(nothing) === nothing
end

# ── end-to-end over a real loopback connection ───────────────────────────────

function _pmce_echo_server(; compress::Bool)
    return W.listen!("127.0.0.1", 0; compress = compress) do ws
        for msg in ws
            W.send(ws, msg)
        end
    end
end

_pmce_port(server) = parse(Int, split(W.server_addr(server), ":")[end])

@testset "permessage-deflate end-to-end echo" begin
    server = _pmce_echo_server(compress = true)
    try
        port = _pmce_port(server)
        W.open("ws://127.0.0.1:$port/"; compress = true) do ws
            @test ws.codec.pmce !== nothing
            cases = Any[
                "hello compressed world",
                repeat("compress me ", 500),
                collect(rand(UInt8, 4000)),
                "",
                "unicode payload: ☃ 日本語 🚀",
                collect(0x00:0xff),
            ]
            for msg in cases
                W.send(ws, msg)
                got = W.receive(ws)
                want = msg isa String ? msg : Vector{UInt8}(msg)
                gotn = got isa String ? got : Vector{UInt8}(got)
                @test gotn == want
            end
            # context takeover across consecutive messages
            W.send(ws, "repeatable"); @test W.receive(ws) == "repeatable"
            W.send(ws, "repeatable"); @test W.receive(ws) == "repeatable"
            # a chunked (iterable) send is compressed as one message
            W.send(ws, ["a-", "b-", "c"]); @test W.receive(ws) == "a-b-c"
        end
    finally
        close(server)
    end
end

@testset "permessage-deflate negotiation fallbacks end-to-end" begin
    # server disabled: client offer is declined, connection works uncompressed
    server_off = _pmce_echo_server(compress = false)
    try
        port = _pmce_port(server_off)
        W.open("ws://127.0.0.1:$port/"; compress = true) do ws
            @test ws.codec.pmce === nothing
            W.send(ws, "plain"); @test W.receive(ws) == "plain"
        end
    finally
        close(server_off)
    end

    # client disabled, server enabled: no extension offered, so none negotiated
    server_on = _pmce_echo_server(compress = true)
    try
        port = _pmce_port(server_on)
        W.open("ws://127.0.0.1:$port/"; compress = false) do ws
            @test ws.codec.pmce === nothing
            W.send(ws, "plain"); @test W.receive(ws) == "plain"
        end
    finally
        close(server_on)
    end
end
