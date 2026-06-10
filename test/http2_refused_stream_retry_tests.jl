using Test
using HTTP
using Reseau

const HT = HTTP
const ND = Reseau.HostResolvers
const NC = Reseau.TCP

# RFC 9113 §7 error codes
const _RSR_REFUSED_STREAM = UInt32(0x7)
const _RSR_NO_ERROR = UInt32(0x0)

function _rsr_write_frame!(conn::NC.Conn, frame::HT.AbstractFrame)
    io = IOBuffer()
    HT.write_frame!(io, frame)
    bytes = take!(io)
    total = 0
    while total < length(bytes)
        n = write(conn, bytes[(total + 1):end])
        n > 0 || error("expected write progress")
        total += n
    end
    return nothing
end

function _rsr_read_preface!(conn::NC.Conn)
    n = length(HT._H2_PREFACE)
    offset = 0
    while offset < n
        chunk = Vector{UInt8}(undef, n - offset)
        nr = readbytes!(conn, chunk)
        nr > 0 || error("unexpected EOF reading client preface")
        offset += nr
    end
    return nothing
end

function _rsr_next_headers!(reader)::HT.HeadersFrame
    while true
        frame = HT.read_frame!(reader)
        frame isa HT.HeadersFrame && return frame::HT.HeadersFrame
        frame isa HT.WindowUpdateFrame && continue
        frame isa HT.SettingsFrame && continue
        frame isa HT.PingFrame && continue
        error("expected headers frame, got $(typeof(frame))")
    end
end

# Scripted h2 server: refuses the first `refuse_first` requests (RST_STREAM
# REFUSED_STREAM, or GOAWAY rejecting the in-flight stream), then answers 200.
# An accept loop plus a per-connection headers loop keeps it agnostic to
# whether the client retries on the same connection or on a new one.
function _rsr_serve!(listener; scenario::Symbol, refuse_first::Int = 1)
    attempts = Threads.Atomic{Int}(0)
    conns = Threads.Atomic{Int}(0)
    accept_task = errormonitor(Threads.@spawn begin
        while true
            conn = try
                NC.accept(listener)
            catch
                break   # listener closed: end of test
            end
            Threads.atomic_add!(conns, 1)
            errormonitor(Threads.@spawn begin
                try
                    _rsr_read_preface!(conn)
                    _rsr_write_frame!(conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
                    reader = HT._ConnReader(conn)
                    encoder = HT.Encoder()
                    while true
                        hf = _rsr_next_headers!(reader)
                        attempt = Threads.atomic_add!(attempts, 1) + 1
                        if attempt <= refuse_first
                            if scenario === :rst
                                _rsr_write_frame!(conn, HT.RSTStreamFrame(hf.stream_id, _RSR_REFUSED_STREAM))
                            elseif scenario === :goaway
                                _rsr_write_frame!(conn, HT.GoAwayFrame(UInt32(0), _RSR_NO_ERROR, UInt8[]))
                                break
                            else
                                error("unknown scenario $scenario")
                            end
                        else
                            encoded = HT.encode_header_block(encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
                            _rsr_write_frame!(conn, HT.HeadersFrame(hf.stream_id, true, true, encoded))
                        end
                    end
                catch
                    # client tore the connection down (expected on error paths)
                finally
                    HTTP.@try_ignore NC.close(conn)
                end
            end)
        end
    end)
    return attempts, conns, accept_task
end

function _rsr_request(url)
    return try
        HT.get(url; protocol = :h2, retry = true, connect_timeout = 5, request_timeout = 15)
    catch err
        err
    end
end

@testset "HTTP/2 retry of guaranteed-unprocessed streams (RFC 9113 §8.7)" begin

# A stream reset with REFUSED_STREAM is guaranteed unprocessed (RFC 9113 §8.7)
# and must be retried transparently.
@testset "HTTP/2 client retries a stream reset with REFUSED_STREAM" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    url = "http://" * ND.join_host_port("127.0.0.1", Int(laddr.port)) * "/"
    attempts, conns, accept_task = _rsr_serve!(listener; scenario = :rst)
    try
        result = _rsr_request(url)
        @info "REFUSED_STREAM scenario" result attempts[] conns[]
        @test attempts[] == 2                  # the refused attempt was retried
        @test result isa HT.Response
        result isa HT.Response && @test (result::HT.Response).status == 200
    finally
        HTTP.@try_ignore NC.close(listener)
        HTTP.@try_ignore wait(accept_task)
    end
end

# A stream rejected by GOAWAY (stream_id > last_stream_id) is likewise
# unprocessed and must be retried, necessarily on a new connection.
@testset "HTTP/2 client retries a stream rejected by GOAWAY" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    url = "http://" * ND.join_host_port("127.0.0.1", Int(laddr.port)) * "/"
    attempts, conns, accept_task = _rsr_serve!(listener; scenario = :goaway)
    try
        result = _rsr_request(url)
        @info "GOAWAY scenario" result attempts[] conns[]
        @test attempts[] == 2
        @test conns[] == 2                     # GOAWAY drains the first connection
        @test result isa HT.Response
        result isa HT.Response && @test (result::HT.Response).status == 200
    finally
        HTTP.@try_ignore NC.close(listener)
        HTTP.@try_ignore wait(accept_task)
    end
end

end # parent testset
