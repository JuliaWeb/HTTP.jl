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
        frame isa HT.DataFrame && continue      # POST request bodies
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
function _rsr_serve!(listener; scenario::Symbol, refuse_first::Int = 1, rst_code::UInt32 = _RSR_REFUSED_STREAM)
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
                                _rsr_write_frame!(conn, HT.RSTStreamFrame(hf.stream_id, rst_code))
                            elseif scenario === :goaway
                                _rsr_write_frame!(conn, HT.GoAwayFrame(UInt32(0), _RSR_NO_ERROR, UInt8[]))
                                # Read until the client closes. Closing with request
                                # bytes still unread sends a reset, and the client's
                                # stack may then drop the GOAWAY before reading it.
                                while true
                                    HT.read_frame!(reader)
                                end
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

function _rsr_request(url; method::String = "GET", body::String = "")
    return try
        HT.request(method, url, Pair{String, String}[], body;
                   protocol = :h2, retry = true, connect_timeout = 5, request_timeout = 15)
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

# Other reset codes give no unprocessed guarantee: they must surface, not retry.
@testset "HTTP/2 client does not retry a stream reset with CANCEL" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    url = "http://" * ND.join_host_port("127.0.0.1", Int(laddr.port)) * "/"
    attempts, conns, accept_task = _rsr_serve!(listener; scenario = :rst, rst_code = UInt32(0x8))
    try
        result = _rsr_request(url)
        @test attempts[] == 1                  # surfaced on first occurrence
        @test result isa HT.H2StreamResetError
        result isa HT.H2StreamResetError && @test occursin("CANCEL", sprint(showerror, result))
    finally
        HTTP.@try_ignore NC.close(listener)
        HTTP.@try_ignore wait(accept_task)
    end
end

# §8.7 lifts the idempotency gate: requests on guaranteed-unprocessed streams
# are retried even when non-idempotent (the body, here in-memory, is replayable).
@testset "HTTP/2 client retries a refused POST (non-idempotent)" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    url = "http://" * ND.join_host_port("127.0.0.1", Int(laddr.port)) * "/"
    attempts, conns, accept_task = _rsr_serve!(listener; scenario = :rst)
    try
        result = _rsr_request(url; method = "POST", body = "ping")
        @test attempts[] == 2
        @test result isa HT.Response
        result isa HT.Response && @test (result::HT.Response).status == 200
    finally
        HTTP.@try_ignore NC.close(listener)
        HTTP.@try_ignore wait(accept_task)
    end
end

@testset "HTTP/2 client retries a POST rejected by GOAWAY" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    url = "http://" * ND.join_host_port("127.0.0.1", Int(laddr.port)) * "/"
    attempts, conns, accept_task = _rsr_serve!(listener; scenario = :goaway)
    try
        result = _rsr_request(url; method = "POST", body = "ping")
        @test attempts[] == 2
        @test conns[] == 2
        @test result isa HT.Response
        result isa HT.Response && @test (result::HT.Response).status == 200
    finally
        HTTP.@try_ignore NC.close(listener)
        HTTP.@try_ignore wait(accept_task)
    end
end

# A cancelled POST has no unprocessed guarantee: no retry, the reset surfaces.
@testset "HTTP/2 client does not retry a cancelled POST" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    url = "http://" * ND.join_host_port("127.0.0.1", Int(laddr.port)) * "/"
    attempts, conns, accept_task = _rsr_serve!(listener; scenario = :rst, rst_code = UInt32(0x8))
    try
        result = _rsr_request(url; method = "POST", body = "ping")
        @test attempts[] == 1
        @test result isa HT.H2StreamResetError
    finally
        HTTP.@try_ignore NC.close(listener)
        HTTP.@try_ignore wait(accept_task)
    end
end

@testset "H2StreamResetError names RFC 9113 §7 error codes" begin
    @test sprint(showerror, HT.H2StreamResetError(UInt32(0x7))) == "HTTP/2 stream reset by peer: REFUSED_STREAM"
    @test sprint(showerror, HT.H2StreamResetError(UInt32(0xb))) == "HTTP/2 stream reset by peer: ENHANCE_YOUR_CALM"
    @test endswith(sprint(showerror, HT.H2StreamResetError(UInt32(0xff))), ": 0xff")
end

end # parent testset

# The GOAWAY can close the connection before the request task writes any body
# DATA. The upload must then stop, and the request fail with the retryable
# H2GoAwayError instead of "connection is closed".
@testset "HTTP/2 client reports GOAWAY for a body written after the connection closed" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    attempts, conns, accept_task = _rsr_serve!(listener; scenario = :goaway)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        sent = Ref(false)
        body = HT.CallbackBody(dst -> begin
            sent[] && return 0
            # Hold the first chunk until the read loop has handled the GOAWAY,
            # closed the connection, and exited.
            lock(h2_conn.state_lock)
            try
                while !(@atomic :acquire h2_conn.closed) || h2_conn.read_task !== nothing
                    wait(h2_conn.read_loop_condition)
                end
            finally
                unlock(h2_conn.state_lock)
            end
            sent[] = true
            dst[1] = UInt8('x')
            return 1
        end, () -> nothing)
        request = HT.Request("POST", "/"; host = address, body = body, content_length = -1)
        err = try
            HT.h2_roundtrip!(h2_conn, request)
            nothing
        catch caught
            caught
        end
        @test err isa HT.H2GoAwayError
        @test attempts[] == 1
    finally
        close(h2_conn)
        HTTP.@try_ignore NC.close(listener)
        HTTP.@try_ignore wait(accept_task)
    end
end
