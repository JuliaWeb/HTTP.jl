using Test
using HTTP

const HT = HTTP

@testset "HTTP2Settings construction validation" begin
    # Invalid windows are rejected at HTTP2Settings construction, before any
    # Client, Server, or socket work.
    @test_throws ArgumentError HT.HTTP2Settings(initial_window_size = 0)
    @test_throws ArgumentError HT.HTTP2Settings(initial_window_size = Int(0x7fff_ffff) + 1)
    @test_throws ArgumentError HT.HTTP2Settings(connection_window_size = Int(0x7fff_ffff) + 1)
    # The per-stream window may be set below the protocol default for tighter
    # backpressure, but the connection-level window cannot be advertised below it
    # (it starts at the default and is only ever enlarged by a WINDOW_UPDATE).
    @test HT.HTTP2Settings(initial_window_size = 1_024) isa HT.HTTP2Settings
    @test_throws ArgumentError HT.HTTP2Settings(connection_window_size = 65_534)
    # The defaults are the protocol default window on both axes.
    @test HT.HTTP2Settings() isa HT.HTTP2Settings
    @test HT.HTTP2Settings().initial_window_size == HT._H2_DEFAULT_WINDOW_SIZE
    @test HT.HTTP2Settings().connection_window_size == HT._H2_DEFAULT_WINDOW_SIZE
end

@testset "HTTP2Settings derives the receive buffer cap from the window" begin
    # The per-stream buffer cap is the larger of the configured window and the
    # default cap, so a small window keeps the default and a large window grows it.
    @test HT._h2_buffered_bytes(HT.HTTP2Settings()) == HT._H2_DEFAULT_MAX_BUFFERED_BYTES
    @test HT._h2_buffered_bytes(HT.HTTP2Settings(initial_window_size = 16_384)) ==
        HT._H2_DEFAULT_MAX_BUFFERED_BYTES
    @test HT._h2_buffered_bytes(HT.HTTP2Settings(initial_window_size = 1_048_576)) == 1_048_576
end
