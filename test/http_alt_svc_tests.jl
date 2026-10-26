using Test
using HTTP

# Alt-Svc (RFC 7838): parsing the header, and the client's cache of HTTP/3
# alternatives per origin.

const AS = HTTP

_as_entries(v) = [(e.protocol, e.host, e.port, e.max_age_s) for e in AS._parse_alt_svc(v)::Vector{AS._AltSvcEntry}]

@testset "Alt-Svc parsing" begin
    @test _as_entries("h3=\":443\"; ma=86400, h3-29=\":443\"; ma=86400") ==
        [("h3", "", 443, 86400), ("h3-29", "", 443, 86400)]
    @test AS._parse_alt_svc("clear") === :clear
    @test AS._parse_alt_svc(" clear ") === :clear
    # The default freshness is 24 hours.
    @test _as_entries("h3=\"alt.example.com:8443\"") == [("h3", "alt.example.com", 8443, 86400)]
    @test _as_entries("h3=\"[2001:db8::1]:443\";ma=60;persist=1") == [("h3", "2001:db8::1", 443, 60)]
    # Malformed alternatives are skipped, the rest kept.
    @test _as_entries("h3=443, h3=\":abc\", h3=\":0\", =\":443\", h3=\":70000\", h2=\":443\"") == [("h2", "", 443, 86400)]
    # Commas and semicolons inside quoted parameters do not split entries.
    @test _as_entries("h3=\":443\"; foo=\"a,b;c\", h2=\":444\"") == [("h3", "", 443, 86400), ("h2", "", 444, 86400)]
    # Protocol IDs are percent-encoded.
    @test _as_entries("w%3Dx%3Ay=\":443\"") == [("w=x:y", "", 443, 86400)]
    # A bad max-age falls back to the default.
    @test _as_entries("h3=\":443\"; ma=soon") == [("h3", "", 443, 86400)]
    @test isempty(_as_entries(""))
end

@testset "Alt-Svc cache" begin
    cache = AS._AltSvcCache()
    now = Int64(1_000_000_000_000)
    second = Int64(1_000_000_000)
    @test AS._alt_svc_lookup(cache, "example.com:443", now) === nothing
    AS._alt_svc_record!(cache, "example.com:443", ["h2=\":443\"", "h3=\":8443\"; ma=100"], now)
    @test AS._alt_svc_lookup(cache, "example.com:443", now) == "example.com:8443"
    @test AS._alt_svc_lookup(cache, "example.com:443", now + 99 * second) == "example.com:8443"
    @test AS._alt_svc_lookup(cache, "example.com:443", now + 100 * second) === nothing
    # A header with no h3 alternative leaves the cache as it was; `clear` empties it.
    AS._alt_svc_record!(cache, "example.com:443", ["h3=\":443\""], now)
    AS._alt_svc_record!(cache, "example.com:443", ["h2=\":443\""], now)
    @test AS._alt_svc_lookup(cache, "example.com:443", now) == "example.com:443"
    AS._alt_svc_record!(cache, "example.com:443", ["clear"], now)
    @test AS._alt_svc_lookup(cache, "example.com:443", now) === nothing
    # Alternative hosts are kept, bracketed when IPv6.
    AS._alt_svc_record!(cache, "example.com:443", ["h3=\"[::1]:443\""], now)
    @test AS._alt_svc_lookup(cache, "example.com:443", now) == "[::1]:443"
    # A broken alternative is not used until the broken period ends.
    AS._alt_svc_mark_broken!(cache, "example.com:443", now)
    @test AS._alt_svc_lookup(cache, "example.com:443", now) === nothing
    AS._alt_svc_record!(cache, "example.com:443", ["h3=\":443\""], now)
    @test AS._alt_svc_lookup(cache, "example.com:443", now) === nothing
    @test AS._alt_svc_broken(cache, "example.com:443", now)
    later = now + AS._ALT_SVC_BROKEN_NS
    @test !AS._alt_svc_broken(cache, "example.com:443", later)
    AS._alt_svc_record!(cache, "example.com:443", ["h3=\":443\""], later)
    @test AS._alt_svc_lookup(cache, "example.com:443", later) == "example.com:443"
    # Origins are separate.
    @test AS._alt_svc_lookup(cache, "other.example:443", later) === nothing
end
