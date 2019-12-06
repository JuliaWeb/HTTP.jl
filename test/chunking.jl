using Test
using HTTP
using BufferedStreams

# For more information see: https://github.com/JuliaWeb/HTTP.jl/pull/288
@testset "Chunking" begin
    sz = 90
    hex(n) = string(n, base=16)
    encoded_data = "$(hex(sz + 9))\r\n" * "data: 1$(repeat("x", sz))\n\n" * "\r\n" *
                   "$(hex(sz + 9))\r\n" * "data: 2$(repeat("x", sz))\n\n" * "\r\n" *
                   "$(hex(sz + 9))\r\n" * "data: 3$(repeat("x", sz))\n\n" * "\r\n"
    decoded_data = "data: 1$(repeat("x", sz))\n\n" *
                   "data: 2$(repeat("x", sz))\n\n" *
                   "data: 3$(repeat("x", sz))\n\n"
    split1 = 106
    split2 = 300

    @async HTTP.listen("127.0.0.1", 8091) do http
        startwrite(http)
        tcp = http.stream.c.io

        write(tcp, encoded_data[1:split1])
        flush(tcp)
        sleep(1)

        write(tcp, encoded_data[split1+1:split2])
        flush(tcp)
        sleep(1)

        write(tcp, encoded_data[split2+1:end])
        flush(tcp)
    end

    sleep(1)

    r = HTTP.get("http://127.0.0.1:8091")

    @test String(r.body) == decoded_data

    # Ignore byte-by-byte read warning
    ll = Base.CoreLogging.min_enabled_level(Base.CoreLogging.global_logger())
    Base.CoreLogging.disable_logging(Base.CoreLogging.Warn)

    for wrap in (identity, BufferedInputStream)
        r = ""

        HTTP.open("GET", "http://127.0.0.1:8091") do io
            io = wrap(io)
            x = split(decoded_data, "\n")

            for i in 1:6
                l = readline(io)
                @test l == x[i]
                r *= l * "\n"
            end
        end

        @test r == decoded_data
    end
    Base.CoreLogging.disable_logging(ll)
end