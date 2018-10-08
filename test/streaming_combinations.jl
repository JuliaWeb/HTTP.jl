# Untested work in progres...

packet_count = 1000

data_producers = [

    :large_packet_stream => http -> begin
        for i in 1:packet_count
            send_large_chunk(http)
        end
    end,

    :small_packet_stream => http -> begin
        for i in 1:packet_count
            send_small_chunk(http)
        end
    end,

    :large_packets_with_delays => http -> begin
        for i in 1:packet_count
            sleep(0.1)
            send_large_chunk(http)
        end
    end,

    :small_packets_with_delays => http -> begin
        for i in 1:packet_count
            sleep(0.1)
            send_large_chunk(http)
        end
    end,

    :random_packets_and_delays => http -> begin
        for i in 1:packet_count
            sleep(rand(1:300)/1000)
            send_chunk(http, rand(10:10000)
        end
    end
]

idle_behaviours = [

    :delay_1_minute => http -> sleep(60),

    :no_delay => nothing
]

close_behaviours = [

    :tls_close_notify => http -> begin
        closewrite(http)
        close(http.stream.c::SSLContext)
    end,

    :tcp_close => http -> begin
        closewrite(http)
        close(http.stream.c.bio::TCPSocket)
    end
]

combinations = []
for p1 in data_producers,
    p2 in data_producers,
    i in idle_behaviours,
    c in close_behaviours
    push!(combinations, [p1..., p2..., i..., c...])
end
using Random
combinations = Iterators.Stateful(Iterators.cycle(shuffle(combinations)))

timestamp() = string(round(Int, time() * 1000))

HTTP.listen("127.0.0.1", 8080) do http::HTTP.Stream

    p1n, produce1f,
    p2n, produce2f,
    in, idlef,
    cn, closef = popfirst!(combinations)

    name = "$p1n, $p2n, $in and $cn")
    println(name)

    HTTP.setheader(http, "x-test-cobination" => name)
    HTTP.setheader(http, "x-test-tzero" => timestamp())

    produce1f(http)
    produce2f(http)
    idlef(http)
    closef(http)
end

send_small_chunk(http, 10)
send_large_chunk(http, 1000)

send_chunk(http, size)
    chunk = IOBuffer()
    write(chunk, timestamp(), "\n")
    while size > 0
        write(chunk, "0123456789")
        size -= 10
    end
    write(http, chunk)
end
