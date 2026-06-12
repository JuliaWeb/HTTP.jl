# HTTP client transport, connection pooling, and low-level HTTP/1 roundtrip APIs.

using CodecZlib
using Reseau.TCP
using Reseau.HostResolvers
using Reseau.TLS
using Reseau.IOPoll

const _CONN_READER_DEFAULT_BUFFER_BYTES = 16 * 1024
const _TRANSPORT_WRITE_BODY_CHUNK_BYTES = 16 * 1024
const _TRANSPORT_EXPECT_CONTINUE_TIMEOUT_NS = Int64(1_000_000_000)
const _REQUEST_WRITE_CONTINUE_PENDING = UInt8(0x0)
const _REQUEST_WRITE_CONTINUE_ALLOWED = UInt8(0x1)
const _REQUEST_WRITE_CONTINUE_SUPPRESSED = UInt8(0x2)
const _H1_BODY_EMPTY = UInt8(0x0)
const _H1_BODY_FIXED = UInt8(0x1)
const _H1_BODY_CHUNKED = UInt8(0x2)
const _H1_BODY_EOF = UInt8(0x3)
const _TransportHostResolver = typeof(HostResolvers.HostResolver())

"""
    _RequestDeadlineWriteIO(inner, conn, request)

Small write-through adapter that reapplies the request's current write deadline
before each outbound body write.
"""
mutable struct _RequestDeadlineWriteIO{S} <: IO
    inner::S
    conn
    request::Request
end

"""
    _ConnReader(conn, buffer_bytes=16*1024)

Buffered `IO` adapter layered over `TCP.Conn` or `TLS.Conn`.

HTTP/1 parsing wants a byte-oriented reader with a small amount of lookahead so
it can parse lines and then continue reading bodies from the same transport.
This type provides that without forcing the transport types themselves to own
HTTP-specific buffering policy.
"""
function _ConnReader(conn::Union{TCP.Conn,TLS.Conn}, buffer_bytes::Integer=_CONN_READER_DEFAULT_BUFFER_BYTES)
    buffer_bytes > 0 || throw(ArgumentError("buffer_bytes must be > 0"))
    return _ConnReader(Vector{UInt8}(undef, Int(buffer_bytes)), 1, 0, conn)
end

@inline function _set_conn_reader_conn!(reader::_ConnReader, conn::Union{TCP.Conn,TLS.Conn})::Nothing
    if conn isa TCP.Conn
        reader.conn = conn
    else
        reader.conn = conn::TLS.Conn
    end
    return nothing
end

@inline function _conn_reader_available(reader::_ConnReader)::Int
    reader.next > reader.stop && return 0
    return reader.stop - reader.next + 1
end

@inline function _apply_request_write_deadline!(io::_RequestDeadlineWriteIO)::Nothing
    _set_conn_write_deadline!(io.conn::Conn, _request_write_deadline_ns(io.request))
    return nothing
end

function Base.write(io::_RequestDeadlineWriteIO, b::UInt8)::Int
    _apply_request_write_deadline!(io)
    return write(io.inner, b)
end

function _request_deadline_write_bytes!(io::_RequestDeadlineWriteIO, data::AbstractVector{UInt8})::Int
    _apply_request_write_deadline!(io)
    return write(io.inner, data)
end

Base.write(io::_RequestDeadlineWriteIO, data::Vector{UInt8})::Int = _request_deadline_write_bytes!(io, data)
Base.write(io::_RequestDeadlineWriteIO, data::StridedVector{UInt8})::Int = _request_deadline_write_bytes!(io, data)
Base.write(io::_RequestDeadlineWriteIO, data::AbstractVector{UInt8})::Int = _request_deadline_write_bytes!(io, data)

# Hook unsafe_write instead of write(::IO, ::Union{String, SubString{String}}):
# Base's generic string write funnels through unsafe_write, so strings still
# get the deadline applied, while extending `write` for String on a new IO
# type invalidates every abstractly-inferred `write(::IO, ::String)` call site
# in the ecosystem (measured: 1383 invalidated instances at `using` time).
function Base.unsafe_write(io::_RequestDeadlineWriteIO, p::Ptr{UInt8}, n::UInt)::Int
    _apply_request_write_deadline!(io)
    return unsafe_write(io.inner, p, n)
end

@inline function _fill_conn_reader!(reader::_ConnReader)::Int
    conn = reader.conn
    n = if conn isa TCP.Conn
        readbytes!(conn, reader.buf; all=false)
    elseif conn isa TLS.Conn
        readbytes!(conn, reader.buf; all=false)
    else
        error("unexpected _ConnReader conn type")
    end
    reader.next = 1
    reader.stop = n
    return n
end

function _upcoming_header_keys(reader::_ConnReader)::Int
    _conn_reader_available(reader) == 0 && return 0
    nkeys = 0
    line_start = reader.next
    i = reader.next
    while i <= reader.stop && nkeys < 1000
        if @inbounds(reader.buf[i]) == 0x0a
            line_len = i - line_start + 1
            if line_len == 1
                break
            end
            first = @inbounds(reader.buf[line_start])
            if first == 0x0d && line_len == 2
                break
            end
            if first != 0x20 && first != 0x09
                nkeys += 1
            end
            line_start = i + 1
        end
        i += 1
    end
    return nkeys
end

"""
    Conn

Internal pooled HTTP/1 connection record. It bundles the underlying transport,
the parser's `_ConnReader`, a reusable request serialization buffer, and a few
small pieces of pooling metadata such as `reused` and `last_used_ns`.
"""
mutable struct Conn
    key::String
    address::String
    secure::Bool
    tcp::Union{Nothing,TCP.Conn}
    tls::Union{Nothing,TLS.Conn}
    reader::_ConnReader
    request_buf::IOBuffer
    reused::Bool
    @atomic closed::Bool
    last_used_ns::Int64
end

const _CONN_WAITER_WAITING = UInt8(0)
const _CONN_WAITER_CONN = UInt8(1)
const _CONN_WAITER_DIAL = UInt8(2)
const _CONN_WAITER_ERROR = UInt8(3)
const _CONN_WAITER_CANCELED = UInt8(4)

mutable struct _ConnWaiter
    key::String
    signal::Threads.Event
    conn::Union{Nothing,Conn}
    err::Union{Nothing,Exception}
    @atomic state::UInt8
end

function _ConnWaiter(key::String)
    return _ConnWaiter(key, Threads.Event(true), nothing, nothing, _CONN_WAITER_WAITING)
end

mutable struct _RequestWriteState
    expects_continue::Bool
    @atomic continue_state::UInt8
    @atomic stop_upload::Bool
    @atomic allow_writer_close::Bool
    @atomic head_written::Bool
    @atomic writer_done::Bool
end

function _RequestWriteState(expects_continue::Bool)
    return _RequestWriteState(expects_continue, _REQUEST_WRITE_CONTINUE_PENDING, false, true, false, false)
end

"""
    Transport(; ...)

Connection-pooling transport for HTTP/1 requests.

It owns dial/TLS policy and decides when an idle connection can be reused
versus closed.

`max_conns_per_host = 0` leaves per-host concurrency unlimited. Positive values
bound the total live HTTP/1 connections (idle, in-flight, and dialing) for one
pool key and cause additional acquires to wait for direct handoff or a freed
dial slot.
"""
mutable struct Transport
    host_resolver::_TransportHostResolver
    tls_config::Union{Nothing,TLS.Config}
    proxy::ProxyConfig
    retry_bucket::Union{Nothing,RetryBucket}
    max_idle_per_host::Int
    max_idle_total::Int
    max_conns_per_host::Int
    idle_timeout_ns::Int64
    lock::ReentrantLock
    idle::Dict{String,Vector{Conn}}
    waiters::Dict{String,Vector{_ConnWaiter}}
    conns_per_host::Dict{String,Int}
    @atomic idle_total::Int
    @atomic closed::Bool
end

mutable struct H1Body <: AbstractBody
    kind::UInt8
    reader::_ConnReader
    transport::Transport
    conn::Conn
    request::Request
    trailers::Headers
    remaining::Int64
    max_line_bytes::Int
    max_header_bytes::Int
    reusable::Bool
    manage_conn::Bool
    done::Bool
    @atomic closed::Bool
    @atomic released::Bool
    cancel_context::Union{Nothing,RequestContext}
    cancel_callback::Union{Nothing,Function}
end

function Transport(;
    tls_config::Union{Nothing,TLS.Config}=nothing,
    proxy=nothing,
    retry_bucket::Union{Nothing,RetryBucket}=RetryBucket(),
    max_idle_per_host::Integer=2,
    max_idle_total::Integer=64,
    max_conns_per_host::Integer=0,
    idle_timeout_ns::Integer=Int64(90_000_000_000),
)
    max_idle_per_host > 0 || throw(ArgumentError("max_idle_per_host must be > 0"))
    max_idle_total > 0 || throw(ArgumentError("max_idle_total must be > 0"))
    max_conns_per_host >= 0 || throw(ArgumentError("max_conns_per_host must be >= 0"))
    idle_timeout_ns >= 0 || throw(ArgumentError("idle_timeout_ns must be >= 0"))
    host_resolver = HostResolvers.HostResolver()
    return Transport(
        host_resolver,
        tls_config,
        _normalize_proxy_config(proxy),
        retry_bucket,
        Int(max_idle_per_host),
        Int(max_idle_total),
        Int(max_conns_per_host),
        Int64(idle_timeout_ns),
        ReentrantLock(),
        Dict{String,Vector{Conn}}(),
        Dict{String,Vector{_ConnWaiter}}(),
        Dict{String,Int}(),
        0,
        false,
    )
end

@inline function _transport_closed(transport::Transport)::Bool
    return @atomic :acquire transport.closed
end

@inline function _conn_closed(conn::Conn)::Bool
    return @atomic :acquire conn.closed
end

function _conn_stream(conn::Conn)
    if conn.secure
        conn.tls === nothing && throw(ProtocolError("transport connection missing TLS stream"))
        return conn.tls::TLS.Conn
    end
    conn.tcp === nothing && throw(ProtocolError("transport connection missing TCP stream"))
    return conn.tcp::TCP.Conn
end

function _set_conn_read_deadline!(conn::Conn, deadline_ns::Int64)
    if conn.secure
        conn.tls === nothing || TLS.set_read_deadline!(conn.tls::TLS.Conn, deadline_ns)
    else
        conn.tcp === nothing || TCP.set_read_deadline!(conn.tcp::TCP.Conn, deadline_ns)
    end
    return nothing
end

function _set_conn_write_deadline!(conn::Conn, deadline_ns::Int64)
    if conn.secure
        conn.tls === nothing || TLS.set_write_deadline!(conn.tls::TLS.Conn, deadline_ns)
    else
        conn.tcp === nothing || TCP.set_write_deadline!(conn.tcp::TCP.Conn, deadline_ns)
    end
    return nothing
end

@inline function _transport_request_wants_close(request::Request)::Bool
    request.close && return true
    return headercontains(request.headers, "Connection", "close")
end

@inline function _request_expects_continue(request::Request)::Bool
    _request_has_body(request) || return false
    request.proto_major > 1 && return headercontains(request.headers, "Expect", "100-continue")
    request.proto_major == 1 || return false
    request.proto_minor >= 1 || return false
    return headercontains(request.headers, "Expect", "100-continue")
end

@inline function _request_write_should_wait_for_continue(write_state::Union{Nothing,_RequestWriteState})::Bool
    return write_state !== nothing && (write_state::_RequestWriteState).expects_continue
end

@inline function _request_write_continue_state(write_state::_RequestWriteState)::UInt8
    return @atomic :acquire write_state.continue_state
end

@inline function _request_write_mark_continue_allowed!(write_state::_RequestWriteState)::Nothing
    @atomic :release write_state.continue_state = _REQUEST_WRITE_CONTINUE_ALLOWED
    return nothing
end

@inline function _request_write_mark_continue_suppressed!(write_state::_RequestWriteState)::Nothing
    @atomic :release write_state.continue_state = _REQUEST_WRITE_CONTINUE_SUPPRESSED
    return nothing
end

@inline function _request_write_should_stop(write_state::Union{Nothing,_RequestWriteState})::Bool
    write_state === nothing && return false
    return @atomic :acquire (write_state::_RequestWriteState).stop_upload
end

@inline function _request_write_request_stop!(write_state::_RequestWriteState)::Nothing
    @atomic :release write_state.stop_upload = true
    return nothing
end

@inline function _request_write_allows_close(write_state::Union{Nothing,_RequestWriteState})::Bool
    write_state === nothing && return true
    return @atomic :acquire (write_state::_RequestWriteState).allow_writer_close
end

@inline function _request_write_disallow_close!(write_state::_RequestWriteState)::Nothing
    @atomic :release write_state.allow_writer_close = false
    return nothing
end

@inline function _request_write_mark_head_written!(write_state::Union{Nothing,_RequestWriteState})::Nothing
    write_state === nothing && return nothing
    @atomic :release (write_state::_RequestWriteState).head_written = true
    return nothing
end

@inline function _request_write_head_written(write_state::Union{Nothing,_RequestWriteState})::Bool
    write_state === nothing && return true
    return @atomic :acquire (write_state::_RequestWriteState).head_written
end

@inline function _request_write_done(write_state::Union{Nothing,_RequestWriteState})::Bool
    write_state === nothing && return true
    return @atomic :acquire (write_state::_RequestWriteState).writer_done
end

@inline function _request_write_mark_done!(write_state::Union{Nothing,_RequestWriteState})::Nothing
    write_state === nothing && return nothing
    @atomic :release (write_state::_RequestWriteState).writer_done = true
    return nothing
end

@inline function _request_write_head_written_or_done(write_state::Union{Nothing,_RequestWriteState})::Bool
    return _request_write_head_written(write_state) || _request_write_done(write_state)
end

function _expect_continue_deadline_ns(request_deadline::Int64)::Int64
    now_ns = Int64(time_ns())
    timeout_deadline = now_ns > typemax(Int64) - _TRANSPORT_EXPECT_CONTINUE_TIMEOUT_NS ? typemax(Int64) : now_ns + _TRANSPORT_EXPECT_CONTINUE_TIMEOUT_NS
    request_deadline == 0 && return timeout_deadline
    return min(request_deadline, timeout_deadline)
end

function _await_expect_continue!(write_state::_RequestWriteState, request_deadline::Int64)::Bool
    deadline_ns = _expect_continue_deadline_ns(request_deadline)
    while true
        state = _request_write_continue_state(write_state)
        state == _REQUEST_WRITE_CONTINUE_ALLOWED && return true
        state == _REQUEST_WRITE_CONTINUE_SUPPRESSED && return false
        remaining_ns = deadline_ns - Int64(time_ns())
        remaining_ns <= 0 && return true
        IOPoll.timedwait(() -> begin
            state_now = _request_write_continue_state(write_state)
            return state_now == _REQUEST_WRITE_CONTINUE_ALLOWED || state_now == _REQUEST_WRITE_CONTINUE_SUPPRESSED
        end, remaining_ns / 1.0e9; pollint=0.001)
    end
end

function _write_exact_body_transport!(
    io::IO,
    body::AbstractBody,
    expected_len::Int64,
    write_state::Union{Nothing,_RequestWriteState}=nothing,
)::Bool
    expected_len < 0 && throw(ArgumentError("expected_len must be >= 0"))
    expected_len == 0 && return true
    remaining = expected_len
    while remaining > 0
        _request_write_should_stop(write_state) && return false
        to_read = Int(min(Int64(_TRANSPORT_WRITE_BODY_CHUNK_BYTES), remaining))
        buf = Vector{UInt8}(undef, to_read)
        n = body_read!(body, buf)
        n > 0 || throw(ProtocolError("body ended before expected Content-Length bytes were written"))
        _request_write_should_stop(write_state) && return false
        write(io, n == length(buf) ? buf : @view(buf[1:n]))
        remaining -= n
    end
    return true
end

function _write_exact_bytes_body_transport!(
    stream,
    body::BytesBody,
    expected_len::Int64,
    write_state::Union{Nothing,_RequestWriteState}=nothing,
)::Bool
    expected_len < 0 && throw(ArgumentError("expected_len must be >= 0"))
    expected_len == 0 && return true
    available = (length(body.data) - body.next_index) + 1
    available >= expected_len || throw(ProtocolError("body ended before expected Content-Length bytes were written"))
    remaining = expected_len
    while remaining > 0
        _request_write_should_stop(write_state) && return false
        chunk_len = Int(min(Int64(_TRANSPORT_WRITE_BODY_CHUNK_BYTES), remaining))
        stop_index = body.next_index + chunk_len - 1
        chunk = if body.next_index == 1 && stop_index == length(body.data)
            body.data
        else
            view(body.data, body.next_index:stop_index)
        end
        # `stream` is deliberately untyped (multiple transports); without the
        # Int assert `n` infers Any and poisons the loop comparisons with
        # invalidation-prone `>(::Any, ::Int)` edges
        n = Int(write(stream, chunk))
        n == chunk_len || throw(ProtocolError("transport short write"))
        body.next_index = stop_index + 1
        remaining -= n
    end
    return true
end

function _write_chunked_body_transport!(
    io::IO,
    body::AbstractBody,
    trailer_values::Headers,
    write_state::Union{Nothing,_RequestWriteState}=nothing,
)::Bool
    buf = Vector{UInt8}(undef, _TRANSPORT_WRITE_BODY_CHUNK_BYTES)
    while true
        _request_write_should_stop(write_state) && return false
        n = body_read!(body, buf)
        n == 0 && break
        _request_write_should_stop(write_state) && return false
        print(io, string(n, base=16), "\r\n")
        write(io, @view(buf[1:n]))
        write(io, "\r\n")
    end
    write(io, "0\r\n")
    _write_headers!(io, trailer_values)
    write(io, "\r\n")
    return true
end

function _close_conn!(conn::Conn)::Bool
    if _conn_closed(conn)
        return false
    end
    @atomic :release conn.closed = true
    if conn.secure
        if conn.tls !== nothing
            @try_ignore begin
                TLS.close(conn.tls::TLS.Conn)
            end
        end
    else
        if conn.tcp !== nothing
            @try_ignore begin
                TCP.close(conn.tcp::TCP.Conn)
            end
        end
    end
    return true
end

@inline function _notify_waiter!(waiter::_ConnWaiter)
    notify(waiter.signal)
    return nothing
end

@inline function _waiter_waiting(waiter::_ConnWaiter)::Bool
    return (@atomic :acquire waiter.state) == _CONN_WAITER_WAITING
end

function _enqueue_waiter_locked!(transport::Transport, waiter::_ConnWaiter)
    queue = get(() -> _ConnWaiter[], transport.waiters, waiter.key)
    push!(queue, waiter)
    transport.waiters[waiter.key] = queue
    return waiter
end

function _remove_waiter_locked!(transport::Transport, key::String, waiter::_ConnWaiter)
    queue = get(() -> nothing, transport.waiters, key)
    queue === nothing && return nothing
    idx = findfirst(isequal(waiter), queue::Vector{_ConnWaiter})
    idx === nothing || deleteat!(queue::Vector{_ConnWaiter}, idx)
    isempty(queue::Vector{_ConnWaiter}) && delete!(transport.waiters, key)
    return nothing
end

function _next_waiter_locked!(transport::Transport, key::String)::Union{Nothing,_ConnWaiter}
    queue = get(() -> nothing, transport.waiters, key)
    queue === nothing && return nothing
    while !isempty(queue::Vector{_ConnWaiter})
        waiter = popfirst!(queue::Vector{_ConnWaiter})
        if _waiter_waiting(waiter)
            isempty(queue::Vector{_ConnWaiter}) && delete!(transport.waiters, key)
            return waiter
        end
    end
    delete!(transport.waiters, key)
    return nothing
end

@inline function _conn_slots_locked(transport::Transport, key::String)::Int
    return get(() -> 0, transport.conns_per_host, key)
end

function _reserve_conn_slot_locked!(transport::Transport, key::String)::Bool
    current = _conn_slots_locked(transport, key)
    max_per_host = transport.max_conns_per_host
    if max_per_host != 0 && current >= max_per_host
        return false
    end
    transport.conns_per_host[key] = current + 1
    return true
end

function _decrement_conn_slot_locked!(transport::Transport, key::String)
    current = _conn_slots_locked(transport, key)
    current <= 1 ? delete!(transport.conns_per_host, key) : (transport.conns_per_host[key] = current - 1)
    return nothing
end

function _promote_waiter_to_dial_locked!(transport::Transport, key::String)::Union{Nothing,_ConnWaiter}
    transport.max_conns_per_host == 0 && return nothing
    _reserve_conn_slot_locked!(transport, key) || return nothing
    waiter = _next_waiter_locked!(transport, key)
    if waiter === nothing
        _decrement_conn_slot_locked!(transport, key)
        return nothing
    end
    waiter.conn = nothing
    waiter.err = nothing
    @atomic :release waiter.state = _CONN_WAITER_DIAL
    return waiter
end

function _release_conn_slot_locked!(transport::Transport, key::String)::Union{Nothing,_ConnWaiter}
    _decrement_conn_slot_locked!(transport, key)
    _transport_closed(transport) && return nothing
    return _promote_waiter_to_dial_locked!(transport, key)
end

function _close_owned_conn!(transport::Transport, conn::Conn)
    _close_conn!(conn) || return nothing
    waiter = nothing
    lock(transport.lock)
    try
        waiter = _release_conn_slot_locked!(transport, conn.key)
    finally
        unlock(transport.lock)
    end
    waiter === nothing || _notify_waiter!(waiter)
    return nothing
end

function _close_owned_conns!(transport::Transport, conns::Vector{Conn})
    for conn in conns
        _close_owned_conn!(transport, conn)
    end
    return nothing
end

function _deliver_waiter_conn_locked!(waiter::_ConnWaiter, conn::Conn)::Bool
    _waiter_waiting(waiter) || return false
    waiter.conn = conn
    waiter.err = nothing
    @atomic :release waiter.state = _CONN_WAITER_CONN
    return true
end

function _deliver_waiter_error_locked!(waiter::_ConnWaiter, err::Exception)::Bool
    _waiter_waiting(waiter) || return false
    waiter.conn = nothing
    waiter.err = err
    @atomic :release waiter.state = _CONN_WAITER_ERROR
    return true
end

function _wait_for_conn!(transport::Transport, waiter::_ConnWaiter, deadline_ns::Int64)
    while true
        state = @atomic :acquire waiter.state
        if state == _CONN_WAITER_CONN
            return waiter.conn::Conn
        elseif state == _CONN_WAITER_DIAL
            return :dial
        elseif state == _CONN_WAITER_ERROR
            throw(waiter.err::Exception)
        elseif state == _CONN_WAITER_CANCELED
            throw(IOPoll.DeadlineExceededError())
        end
        if deadline_ns == 0
            wait(waiter.signal)
            continue
        end
        now_ns = Int64(time_ns())
        if now_ns >= deadline_ns
            lock(transport.lock)
            try
                if _waiter_waiting(waiter)
                    _remove_waiter_locked!(transport, waiter.key, waiter)
                    @atomic :release waiter.state = _CONN_WAITER_CANCELED
                    throw(IOPoll.DeadlineExceededError())
                end
            finally
                unlock(transport.lock)
            end
            continue
        end
        timeout_s = min((deadline_ns - now_ns) / 1.0e9, 0.05)
        IOPoll.timedwait(() -> (@atomic :acquire waiter.state) != _CONN_WAITER_WAITING, timeout_s; pollint=0.001)
    end
end

function _prepare_conn_for_reuse!(conn::Conn)
    if conn.secure
        conn.tls === nothing || TLS.set_deadline!(conn.tls::TLS.Conn, Int64(0))
    else
        conn.tcp === nothing || TCP.set_deadline!(conn.tcp::TCP.Conn, Int64(0))
    end
    conn.last_used_ns = time_ns()
    return nothing
end

function _host_for_sni(address::AbstractString)::String
    host, _ = HostResolvers.split_host_port(address)
    return host
end

function _copy_tls_config_for_request(
    cfg::TLS.Config,
    server_name::String,
    alpn_protocols::Vector{String},
    curve_preferences::Vector{UInt16},
    handshake_timeout_ns::Int64,
)::TLS.Config
    return TLS.Config(
        server_name,
        cfg.verify_peer,
        cfg.verify_hostname,
        cfg.client_auth,
        cfg.cert_file,
        cfg.key_file,
        cfg.ca_file,
        cfg.client_ca_file,
        alpn_protocols,
        curve_preferences,
        handshake_timeout_ns,
        cfg.min_version,
        cfg.max_version,
        cfg.session_tickets_disabled,
        cfg._session_ticket_keys,
        cfg._client_session_cache,
        cfg._server_session_cache,
        cfg._client_session_cache12,
        cfg._server_session_cache12,
        cfg._client_identity,
        cfg._server_identity,
    )
end

function _effective_tls_config(
    transport::Transport,
    address::String,
    server_name::Union{Nothing,String},
    handshake_timeout_ns::Int64=Int64(0),
)::TLS.Config
    sni = server_name === nothing ? _host_for_sni(address) : server_name
    cfg = transport.tls_config
    if cfg === nothing
        return TLS.Config(
            sni,
            true,
            true,
            TLS.ClientAuthMode.NoClientCert,
            nothing,
            nothing,
            nothing,
            nothing,
            String[],
            UInt16[],
            handshake_timeout_ns,
            TLS.TLS1_2_VERSION,
            nothing,
            false,
            64,
        )
    end
    effective_handshake_timeout_ns = _min_nonzero_ns(cfg.handshake_timeout_ns, handshake_timeout_ns)
    if cfg.server_name !== nothing && effective_handshake_timeout_ns == cfg.handshake_timeout_ns
        return cfg
    end
    return _copy_tls_config_for_request(
        cfg,
        cfg.server_name === nothing ? sni : cfg.server_name::String,
        copy(cfg.alpn_protocols),
        copy(cfg.curve_preferences),
        effective_handshake_timeout_ns,
    )
end

function _write_request_bytes!(stream, request_io::IOBuffer)
    data = take!(request_io)
    request_bytes = length(data)
    request_bytes == 0 && return nothing
    n = write(stream, data)
    n == request_bytes || throw(ProtocolError("transport short write"))
    return nothing
end

@inline function _request_forward_address(request::Request)::String
    if request.host !== nothing
        return request.host::String
    end
    host_values = headers(request.headers, "Host")
    isempty(host_values) && throw(ProtocolError("proxy-forward request is missing host"))
    length(host_values) == 1 || throw(ProtocolError("proxy-forward request has multiple Host headers"))
    return first(host_values)
end

@inline function _request_proxy_authorization(plan::_ProxyPlan)::Union{Nothing,String}
    if plan.mode == _ProxyPlanMode.HTTP_FORWARD
        proxy = plan.proxy
        proxy === nothing && return nothing
        return (proxy::_ProxyTarget).authorization
    end
    return nothing
end

function _prepare_request_headers_for_write(
    request::Request,
    plan::_ProxyPlan,
)::Tuple{Headers,Bool}
    return _prepare_request_headers_for_write(request, _request_proxy_authorization(plan))
end

function _write_start_line!(io::IO, request::Request, plan::_ProxyPlan)
    if plan.mode == _ProxyPlanMode.HTTP_FORWARD
        target = _request_url(false, _request_forward_address(request), request.target)
        print(io, request.method, ' ', target, " HTTP/", Int(request.proto_major), '.', Int(request.proto_minor), "\r\n")
        return nothing
    end
    return _write_start_line!(io, request)
end

function _write_request_head!(
    io::IO,
    request::Request,
    plan::_ProxyPlan,
)::Tuple{Bool,Headers}
    headers, use_chunked = _prepare_request_headers_for_write(request, plan)
    trailer_values = use_chunked ? _prepare_trailer_header!(headers, request.trailers) : Headers()
    _normalize_outgoing_headers!(headers)
    _write_start_line!(io, request, plan)
    _write_headers!(io, headers)
    write(io, "\r\n")
    return use_chunked, trailer_values
end

function _write_request_streaming!(
    request_io::IOBuffer,
    stream,
    request::Request,
    plan::_ProxyPlan,
    write_state::Union{Nothing,_RequestWriteState}=nothing,
    request_deadline::Int64=Int64(0),
)::Bool
    if request.content_length >= 0 && request.body isa BytesBody && !headercontains(request.headers, "Transfer-Encoding", "chunked")
        _write_request_head!(request_io, request, plan)
        _write_request_bytes!(stream, request_io)
        _request_write_mark_head_written!(write_state)
        !_request_write_should_wait_for_continue(write_state) || (_await_expect_continue!(write_state::_RequestWriteState, request_deadline) || return false)
        return _write_exact_bytes_body_transport!(stream, request.body::BytesBody, request.content_length, write_state)
    end
    use_chunked, trailer_values = _write_request_head!(request_io, request, plan)
    _write_request_bytes!(stream, request_io)
    _request_write_mark_head_written!(write_state)
    !_request_has_body(request) && return true
    !_request_write_should_wait_for_continue(write_state) || (_await_expect_continue!(write_state::_RequestWriteState, request_deadline) || return false)
    if use_chunked
        return _write_chunked_body_transport!(stream, request.body, trailer_values, write_state)
    end
    request.content_length < 0 && return true
    body = request.body
    if body isa BytesBody
        return _write_exact_bytes_body_transport!(stream, body::BytesBody, request.content_length, write_state)
    end
    return _write_exact_body_transport!(stream, body, request.content_length, write_state)
end

function _perform_http_connect_tunnel!(
    tcp::TCP.Conn,
    proxy::_ProxyTarget,
    target_address::String,
    deadline_ns::Int64,
)::Nothing
    deadline_ns == 0 || TCP.set_deadline!(tcp, deadline_ns)
    headers = Headers()
    setheader(headers, "Host", target_address)
    proxy.authorization === nothing || setheader(headers, "Proxy-Authorization", proxy.authorization::String)
    request = Request(
        "CONNECT",
        target_address;
        headers=headers,
        host=target_address,
        content_length=0,
    )
    request_io = IOBuffer()
    write_request!(request_io, request)
    _write_request_bytes!(tcp, request_io)
    response = _read_incoming_response(_ConnReader(tcp), request)
    response.head.status == 200 || throw(ProtocolError("proxy CONNECT failed with status $(response.head.status)"))
    body = response.rawbody
    @try_ignore begin
        if body isa EmptyBody
        elseif body isa FixedLengthBody
            body_close!(body)
        elseif body isa ChunkedBody
            body_close!(body)
        elseif body isa EOFBody
            body_close!(body)
        else
            error("unexpected proxy CONNECT response body type")
        end
    end
    return nothing
end

function _new_tcp_conn!(
    plan::_ProxyPlan,
    address::String,
    host_resolver::_TransportHostResolver,
    connect_deadline_ns::Int64=Int64(0),
)::TCP.Conn
    tcp = TCP.connect(host_resolver, "tcp", plan.first_hop_address)
    if plan.mode == _ProxyPlanMode.HTTP_TUNNEL
        proxy = plan.proxy
        proxy === nothing && throw(ProtocolError("proxy CONNECT tunnel is missing proxy config"))
        _perform_http_connect_tunnel!(tcp, proxy::_ProxyTarget, address, connect_deadline_ns)
    end
    return tcp
end

function _new_conn!(
    transport::Transport,
    plan::_ProxyPlan,
    address::String,
    secure::Bool,
    server_name::Union{Nothing,String},
    host_resolver::_TransportHostResolver=transport.host_resolver,
    connect_deadline_ns::Int64=Int64(0),
    tls_handshake_timeout_ns::Int64=Int64(0),
)::Conn
    if secure
        return _new_conn_tls!(
            transport,
            plan,
            address,
            server_name,
            host_resolver,
            connect_deadline_ns,
            tls_handshake_timeout_ns,
        )
    end
    return _new_conn_tcp!(
        plan,
        address,
        host_resolver,
        connect_deadline_ns,
    )
end

function _new_conn_tcp!(
    plan::_ProxyPlan,
    address::String,
    host_resolver::_TransportHostResolver,
    connect_deadline_ns::Int64=Int64(0),
)::Conn
    tcp = _new_tcp_conn!(plan, address, host_resolver, connect_deadline_ns)
    return Conn(plan.pool_key, plan.first_hop_address, false, tcp, nothing, _ConnReader(tcp), IOBuffer(), false, false, time_ns())
end

function _new_conn_tls!(
    transport::Transport,
    plan::_ProxyPlan,
    address::String,
    server_name::Union{Nothing,String},
    host_resolver::_TransportHostResolver=transport.host_resolver,
    connect_deadline_ns::Int64=Int64(0),
    tls_handshake_timeout_ns::Int64=Int64(0),
)::Conn
    tcp = _new_tcp_conn!(plan, address, host_resolver, connect_deadline_ns)
    cfg = _effective_tls_config(transport, address, server_name, tls_handshake_timeout_ns)
    tls = TLS.client(tcp, cfg)
    connect_deadline_ns == 0 || TLS.set_deadline!(tls, connect_deadline_ns)
    TLS.handshake!(tls)
    return Conn(plan.pool_key, plan.first_hop_address, true, tcp, tls, _ConnReader(tls), IOBuffer(), false, false, time_ns())
end

function _evict_expired_idle_locked!(transport::Transport, key::String, now_ns::Int64)::Vector{Conn}
    idle_list = get(() -> nothing, transport.idle, key)
    idle_list === nothing && return Conn[]
    kept = Conn[]
    stale = Conn[]
    for conn in idle_list::Vector{Conn}
        expired = transport.idle_timeout_ns > 0 && (now_ns - conn.last_used_ns) > transport.idle_timeout_ns
        if _conn_closed(conn) || expired
            @atomic :acquire_release transport.idle_total -= 1
            push!(stale, conn)
            continue
        end
        push!(kept, conn)
    end
    if isempty(kept)
        delete!(transport.idle, key)
    else
        transport.idle[key] = kept
    end
    return stale
end

function _acquire_conn!(
    transport::Transport,
    plan::_ProxyPlan,
    address::String,
    secure::Bool,
    server_name::Union{Nothing,String},
    acquire_deadline_ns::Int64=Int64(0),
    host_resolver::_TransportHostResolver=transport.host_resolver,
    connect_deadline_ns::Int64=Int64(0),
    tls_handshake_timeout_ns::Int64=Int64(0),
)::Conn
    _transport_closed(transport) && throw(ProtocolError("transport is closed"))
    waiter = nothing
    while true
        stale = Conn[]
        conn = nothing
        should_dial = false
        lock(transport.lock)
        try
            _transport_closed(transport) && throw(ProtocolError("transport is closed"))
            now_ns = Int64(time_ns())
            append!(stale, _evict_expired_idle_locked!(transport, plan.pool_key, now_ns))
            idle_list = get(() -> nothing, transport.idle, plan.pool_key)
            while idle_list !== nothing && !isempty(idle_list::Vector{Conn})
                conn = pop!(idle_list::Vector{Conn})
                @atomic :acquire_release transport.idle_total -= 1
                isempty(idle_list::Vector{Conn}) && delete!(transport.idle, plan.pool_key)
                if !_conn_closed(conn::Conn)
                    (conn::Conn).reused = true
                    break
                end
                push!(stale, conn::Conn)
                conn = nothing
                idle_list = get(() -> nothing, transport.idle, plan.pool_key)
            end
            if conn === nothing && isempty(stale)
                if _reserve_conn_slot_locked!(transport, plan.pool_key)
                    should_dial = true
                else
                    waiter = _ConnWaiter(plan.pool_key)
                    _enqueue_waiter_locked!(transport, waiter)
                end
            end
        finally
            unlock(transport.lock)
        end
        isempty(stale) || (_close_owned_conns!(transport, stale); continue)
        if conn !== nothing
            return conn::Conn
        end
        if should_dial
            try
                return _new_conn!(
                    transport,
                    plan,
                    address,
                    secure,
                    server_name,
                    host_resolver,
                    connect_deadline_ns,
                    tls_handshake_timeout_ns,
                )
            catch err
                waiter_to_notify = nothing
                lock(transport.lock)
                try
                    waiter_to_notify = _release_conn_slot_locked!(transport, plan.pool_key)
                finally
                    unlock(transport.lock)
                end
                waiter_to_notify === nothing || _notify_waiter!(waiter_to_notify)
                rethrow(err)
            end
        end
        result = _wait_for_conn!(transport, waiter::_ConnWaiter, acquire_deadline_ns)
        if result === :dial
            try
                return _new_conn!(
                    transport,
                    plan,
                    address,
                    secure,
                    server_name,
                    host_resolver,
                    connect_deadline_ns,
                    tls_handshake_timeout_ns,
                )
            catch err
                waiter_to_notify = nothing
                lock(transport.lock)
                try
                    waiter_to_notify = _release_conn_slot_locked!(transport, plan.pool_key)
                finally
                    unlock(transport.lock)
                end
                waiter_to_notify === nothing || _notify_waiter!(waiter_to_notify)
                rethrow(err)
            end
        end
        conn = result::Conn
        conn.reused = true
        return conn
    end
end

function _put_idle_conn!(transport::Transport, conn::Conn)
    if _transport_closed(transport) || _conn_closed(conn)
        _close_owned_conn!(transport, conn)
        return nothing
    end
    try
        _prepare_conn_for_reuse!(conn)
    catch
        _close_owned_conn!(transport, conn)
        return nothing
    end
    waiter_to_notify = nothing
    should_close = false
    lock(transport.lock)
    try
        if _transport_closed(transport)
            should_close = true
        else
            waiter = _next_waiter_locked!(transport, conn.key)
            if waiter !== nothing && _deliver_waiter_conn_locked!(waiter, conn)
                waiter_to_notify = waiter
            else
                idle_list = get(() -> Conn[], transport.idle, conn.key)
                if length(idle_list) >= transport.max_idle_per_host || (@atomic :acquire transport.idle_total) >= transport.max_idle_total
                    should_close = true
                else
                    push!(idle_list, conn)
                    transport.idle[conn.key] = idle_list
                    @atomic :acquire_release transport.idle_total += 1
                end
            end
        end
    finally
        unlock(transport.lock)
    end
    waiter_to_notify === nothing || (_notify_waiter!(waiter_to_notify); return nothing)
    should_close && _close_owned_conn!(transport, conn)
    return nothing
end

"""
    close_idle_connections!()
    close_idle_connections!(client::HTTP.Client)
    close_idle_connections!(transport::HTTP.Transport)

Close all currently idle pooled connections, returning `nothing`. Active
in-flight requests are unaffected.

The no-argument form closes idle connections held by the default client used by
`HTTP.get`, `HTTP.post`, `HTTP.request`, and friends (a no-op if no request has
been made yet). Pass an `HTTP.Client` or `HTTP.Transport` to target a specific
connection pool.
"""
function close_idle_connections!(transport::Transport)
    to_close = Conn[]
    lock(transport.lock)
    try
        for (_, idle_list) in transport.idle
            for conn in idle_list
                push!(to_close, conn)
            end
        end
        empty!(transport.idle)
        @atomic :release transport.idle_total = 0
    finally
        unlock(transport.lock)
    end
    _close_owned_conns!(transport, to_close)
    return nothing
end

"""
    close(transport)

Close `transport` and eagerly drop every idle connection it owns. In-flight
requests are allowed to finish on the connections they already hold.
"""
function Base.close(transport::Transport)
    _transport_closed(transport) && return nothing
    to_close = Conn[]
    waiters_to_notify = _ConnWaiter[]
    err = ProtocolError("transport is closed")
    lock(transport.lock)
    try
        _transport_closed(transport) && return nothing
        @atomic :release transport.closed = true
        for (_, idle_list) in transport.idle
            append!(to_close, idle_list)
        end
        empty!(transport.idle)
        @atomic :release transport.idle_total = 0
        for (_, queue) in transport.waiters
            for waiter in queue
                _deliver_waiter_error_locked!(waiter, err) && push!(waiters_to_notify, waiter)
            end
        end
        empty!(transport.waiters)
    finally
        unlock(transport.lock)
    end
    _close_owned_conns!(transport, to_close)
    foreach(_notify_waiter!, waiters_to_notify)
    return nothing
end

"""
    idle_connection_count(transport; key=nothing)

Return idle pooled connection count globally or for one host key.

When `key === nothing`, returns the transport-wide count. Otherwise `key`
should match the transport's internal pool key such as `https://example.com:443`.
"""
function idle_connection_count(transport::Transport; key::Union{Nothing,AbstractString}=nothing)::Int
    lock(transport.lock)
    try
        if key === nothing
            return @atomic :acquire transport.idle_total
        end
        idle_list = get(() -> nothing, transport.idle, String(key))
        idle_list === nothing && return 0
        return length(idle_list::Vector{Conn})
    finally
        unlock(transport.lock)
    end
end

function Base.read(reader::_ConnReader, ::Type{UInt8})
    if _conn_reader_available(reader) > 0
        b = @inbounds reader.buf[reader.next]
        reader.next += 1
        return b
    end
    n = _fill_conn_reader!(reader)
    n == 0 && throw(EOFError())
    reader.next = 2
    b = @inbounds reader.buf[1]
    return b
end

function Base.readbytes!(reader::_ConnReader, dst::Vector{UInt8}, nb::Integer=length(dst))
    target = min(Int(nb), length(dst))
    target <= 0 && return 0
    total = 0
    available = _conn_reader_available(reader)
    if available > 0
        copied = min(available, target)
        copyto!(dst, 1, reader.buf, reader.next, copied)
        reader.next += copied
        total = copied
        total == target && return total
    end
    while total < target
        n = _fill_conn_reader!(reader)
        n == 0 && break
        copied = min(n, target - total)
        copyto!(dst, total + 1, reader.buf, 1, copied)
        reader.next = copied + 1
        reader.stop = n
        total += copied
    end
    return total
end

@inline function _read_u8(reader::_ConnReader)::UInt8
    if _conn_reader_available(reader) > 0
        b = @inbounds reader.buf[reader.next]
        reader.next += 1
        return b
    end
    n = _fill_conn_reader!(reader)
    n == 0 && throw(ParseError("unexpected EOF while reading HTTP/1 data"))
    reader.next = 2
    b = @inbounds reader.buf[1]
    return b
end

function _readline_crlf(reader::_ConnReader, max_line_bytes::Integer)::String
    max_line_bytes <= 0 && throw(ArgumentError("max_line_bytes must be > 0"))
    # Fast path: line fully contained in the current fill of the conn buffer.
    # This is the common case for HTTP/1 request lines and headers in
    # well-behaved clients, and avoids the per-line Vector{UInt8} allocation
    # and copy that the multi-buffer slow path requires.
    if _conn_reader_available(reader) > 0
        start = reader.next
        stop = reader.stop
        nl_idx = 0
        @inbounds for i in start:stop
            if reader.buf[i] == 0x0a
                nl_idx = i
                break
            end
        end
        if nl_idx > 0
            line_len = nl_idx - start + 1
            line_len > max_line_bytes && throw(ProtocolError("HTTP/1 line exceeds configured max_line_bytes", _PROTOCOL_ERROR_LINE_TOO_LONG))
            reader.next = nl_idx + 1
            # Strip terminator: \r\n preferred, bare \n tolerated.
            content_stop = nl_idx - 1
            if content_stop >= start && @inbounds(reader.buf[content_stop]) == 0x0d
                content_stop -= 1
            end
            content_len = content_stop - start + 1
            content_len <= 0 && return ""
            return unsafe_string(pointer(reader.buf, start), content_len)
        end
    end
    # Slow path: line spans multiple buffer fills.
    bytes = UInt8[]
    while true
        if _conn_reader_available(reader) == 0
            n = _fill_conn_reader!(reader)
            n > 0 || throw(ParseError("unexpected EOF while reading HTTP/1 data"))
        end
        start = reader.next
        stop = reader.stop
        nl_idx = 0
        @inbounds for i in start:stop
            if reader.buf[i] == 0x0a
                nl_idx = i
                break
            end
        end
        if nl_idx == 0
            segment_len = stop - start + 1
            length(bytes) + segment_len > max_line_bytes && throw(ProtocolError("HTTP/1 line exceeds configured max_line_bytes", _PROTOCOL_ERROR_LINE_TOO_LONG))
            append!(bytes, @view(reader.buf[start:stop]))
            reader.next = stop + 1
            continue
        end
        segment_len = nl_idx - start + 1
        length(bytes) + segment_len > max_line_bytes && throw(ProtocolError("HTTP/1 line exceeds configured max_line_bytes", _PROTOCOL_ERROR_LINE_TOO_LONG))
        append!(bytes, @view(reader.buf[start:nl_idx]))
        reader.next = nl_idx + 1
        nbytes = length(bytes)
        if nbytes >= 2 && bytes[nbytes-1] == 0x0d && bytes[nbytes] == 0x0a
            resize!(bytes, nbytes - 2)
            return String(bytes)
        end
    end
end

@inline function _reset_request_buffer!(conn::Conn)::IOBuffer
    request_buf = conn.request_buf
    truncate(request_buf, 0)
    seekstart(request_buf)
    return request_buf
end

@inline function _body_immediately_empty(body::H1Body)::Bool
    return body.kind == _H1_BODY_EMPTY
end

@inline function _body_uses_eof_framing(body::H1Body)::Bool
    return body.kind == _H1_BODY_EOF
end

function trailers(body::H1Body)::Headers
    return copy(body.trailers)
end

@inline function _new_h1_body(
    kind::UInt8,
    reader::_ConnReader,
    transport::Transport,
    conn::Conn,
    request::Request,
    trailers::Headers,
    remaining::Int64,
    max_line_bytes::Int,
    max_header_bytes::Int,
    done::Bool=false,
)::H1Body
    return H1Body(
        kind,
        reader,
        transport,
        conn,
        request,
        trailers,
        remaining,
        max_line_bytes,
        max_header_bytes,
        false,
        false,
        done,
        false,
        false,
        nothing,
        nothing,
    )
end

@inline function _response_reusable(response::_IncomingResponse, request::Request)::Bool
    response.head.close && return false
    _transport_request_wants_close(request) && return false
    headercontains(response.head.headers, "Connection", "close") && return false
    _body_uses_eof_framing(response.rawbody) && return false
    return true
end

@inline function _retryable_method(method::String)::Bool
    return method == "GET" || method == "HEAD" || method == "OPTIONS" || method == "TRACE"
end

@inline function _retryable_request(request::Request)::Bool
    _retryable_method(request.method) || return false
    request.content_length == 0 && return true
    request.body isa EmptyBody && return true
    request.body isa BytesBody && return true
    return false
end

@inline function _retryable_reused_conn_error(err)::Bool
    err isa EOFError && return true
    err isa SystemError && return true
    err isa ParseError && return true
    err isa IOPoll.NetClosingError && return true
    err isa IOPoll.NotPollableError && return true
    err isa IOPoll.DeadlineExceededError && return false
    return false
end

@inline function _request_upload_abort_error(err)::Bool
    err isa EOFError && return true
    err isa SystemError && return true
    err isa IOPoll.NetClosingError && return true
    err isa IOPoll.DeadlineExceededError && return true
    return false
end

@inline function _release_h1_body!(body::H1Body)::Nothing
    body.manage_conn || return nothing
    was_released = @atomic :acquire body.released
    was_released && return nothing
    @atomic :release body.released = true
    _clear_h1_cancel_callback!(body)
    if body.reusable
        _put_idle_conn!(body.transport, body.conn)
    else
        _close_owned_conn!(body.transport, body.conn)
    end
    return nothing
end

@inline function _clear_h1_cancel_callback!(body::H1Body)::Nothing
    ctx = body.cancel_context
    cb = body.cancel_callback
    body.cancel_context = nothing
    body.cancel_callback = nothing
    if ctx !== nothing && cb !== nothing
        _remove_cancel_callback!(ctx::RequestContext, cb::Function)
    end
    return nothing
end

@inline function _arm_h1_body!(
    body::H1Body,
    reusable::Bool,
    cancel_context::Union{Nothing,RequestContext}=nothing,
    cancel_callback::Union{Nothing,Function}=nothing,
)::H1Body
    body.reusable = reusable
    body.manage_conn = true
    body.cancel_context = cancel_context
    body.cancel_callback = cancel_callback
    return body
end

@inline function _finish_h1_body!(body::H1Body)::Nothing
    body.done = true
    @atomic :release body.closed = true
    _release_h1_body!(body)
    return nothing
end

function body_closed(body::H1Body)::Bool
    return @atomic :acquire body.closed
end

function _read_next_h1_chunk!(body::H1Body)::Nothing
    line = _readline_crlf(body.reader, body.max_line_bytes)
    size = _parse_chunk_size(line)
    if size == 0
        parsed_trailers = _read_headers(body.reader, body.max_line_bytes, body.max_header_bytes)
        _validate_incoming_trailers!(parsed_trailers)
        empty!(body.trailers)
        for (key, value) in parsed_trailers
            appendheader(body.trailers, key, value)
        end
        body.done = true
        body.remaining = 0
        return nothing
    end
    body.remaining = size
    return nothing
end

function body_close!(body::H1Body)
    was_closed = @atomic :acquire body.closed
    was_closed && return nothing
    @atomic :release body.closed = true
    body.done || (body.reusable = false)
    body.done = true
    _release_h1_body!(body)
    return nothing
end

function body_read!(body::H1Body, dst::Vector{UInt8})::Int
    isempty(dst) && return 0
    body_closed(body) && return 0
    try
        if body.manage_conn && _request_read_idle_timeout_ns(body.request) > 0
            _set_conn_read_deadline!(body.conn, _request_read_deadline_ns(body.request))
        end
        if body.kind == _H1_BODY_EMPTY
            _finish_h1_body!(body)
            return 0
        elseif body.kind == _H1_BODY_FIXED
            if body.remaining <= 0
                _finish_h1_body!(body)
                return 0
            end
            to_read = min(Int64(length(dst)), body.remaining)
            n = _read_exact!(body.reader, dst, to_read)
            n == to_read || throw(ParseError("truncated fixed-length HTTP/1 body"))
            body.remaining -= n
            body.remaining == 0 && _finish_h1_body!(body)
            return n
        elseif body.kind == _H1_BODY_CHUNKED
            if body.done
                _finish_h1_body!(body)
                return 0
            end
            body.remaining == 0 && _read_next_h1_chunk!(body)
            if body.done
                _finish_h1_body!(body)
                return 0
            end
            to_read = min(Int64(length(dst)), body.remaining)
            n = _read_exact!(body.reader, dst, to_read)
            n == to_read || throw(ParseError("truncated chunked HTTP/1 body"))
            body.remaining -= n
            if body.remaining == 0
                _consume_crlf(body.reader)
            end
            return n
        elseif body.kind == _H1_BODY_EOF
            n = try
                readbytes!(body.reader, dst, length(dst))
            catch err
                err isa EOFError || rethrow(err)
                0
            end
            n == 0 && _finish_h1_body!(body)
            return n
        end
        error("unexpected H1 body kind")
    catch
        body.reusable = false
        body.done = true
        @atomic :release body.closed = true
        _release_h1_body!(body)
        rethrow()
    end
end

function _read_transport_incoming_response(
    reader::_ConnReader,
    transport::Transport,
    conn::Conn,
    request::Request,
    max_line_bytes::Integer=_HTTP1_DEFAULT_MAX_LINE_BYTES,
    max_header_bytes::Integer=_HTTP1_DEFAULT_MAX_HEADER_BYTES,
)
    line = _readline_crlf(reader, max_line_bytes)
    proto_major, proto_minor, status, reason = _parse_status_line(line)
    headers = _read_headers(reader, max_line_bytes, max_header_bytes)
    chunked = _parse_transfer_encoding!(headers, proto_major, proto_minor)
    content_length = _parse_content_length(headers)
    chunked && removeheader(headers, "Content-Length")
    content_length = chunked ? Int64(-1) : content_length
    close = _should_close_connection(headers, proto_major, proto_minor)
    request_is_head = request.method == "HEAD"
    request_is_connect_tunnel = request.method == "CONNECT" && status >= 200 && status < 300
    body = if !_body_allowed_for_status(status) || request_is_head || request_is_connect_tunnel || content_length == 0
        _new_h1_body(
            _H1_BODY_EMPTY,
            reader,
            transport,
            conn,
            request,
            Headers(),
            Int64(0),
            Int(max_line_bytes),
            Int(max_header_bytes),
            true,
        )
    elseif chunked
        trailers = Headers()
        _new_h1_body(
            _H1_BODY_CHUNKED,
            reader,
            transport,
            conn,
            request,
            trailers,
            Int64(0),
            Int(max_line_bytes),
            Int(max_header_bytes),
        )
    elseif content_length > 0
        _new_h1_body(
            _H1_BODY_FIXED,
            reader,
            transport,
            conn,
            request,
            Headers(),
            content_length,
            Int(max_line_bytes),
            Int(max_header_bytes),
        )
    else
        _new_h1_body(
            _H1_BODY_EOF,
            reader,
            transport,
            conn,
            request,
            Headers(),
            Int64(-1),
            Int(max_line_bytes),
            Int(max_header_bytes),
        )
    end
    return _incoming_response_from_parts(
        status,
        reason,
        headers,
        body.trailers,
        body,
        _body_immediately_empty(body) ? Int64(0) : content_length,
        proto_major,
        proto_minor,
        close,
        request,
    )
end

"""
    _roundtrip_incoming!(transport, address, request, false, nothing, transport.proxy, 1)

Execute one HTTP/1 request/response exchange through `transport`.

This is the low-level HTTP/1 path used by the higher-level client APIs. It
returns an `_IncomingResponse` before the public `Response` conversion step.

Throws parser, protocol, transport, TLS, and timeout exceptions depending on
where the exchange fails.
"""
function _roundtrip_incoming!(
    transport::Transport,
    address::AbstractString,
    request::Request,
    secure::Bool=false,
    server_name::Union{Nothing,AbstractString}=nothing,
    proxy_config::ProxyConfig=transport.proxy,
    attempt::Int=1,
)
    request_deadline = _request_deadline_ns(request)
    retry_template = attempt == 1 && _retryable_request(request) ? _copy_request(request) : nothing
    plan = _proxy_plan(proxy_config, secure, String(address))
    connect_host_resolver = _request_connect_host_resolver(transport.host_resolver, request)
    connect_deadline_ns = _request_connect_phase_deadline_ns(transport.host_resolver, request)
    tls_handshake_timeout_ns = _request_connect_phase_timeout_ns(transport.host_resolver, request)
    request_ctx = get_request_context(request)
    canceled(request_ctx) && throw(CanceledError(request_ctx.cancel_message === nothing ? "request canceled" : request_ctx.cancel_message::String))
    conn = _acquire_conn!(
        transport,
        plan,
        String(address),
        secure,
        server_name === nothing ? nothing : String(server_name),
        request_deadline,
        connect_host_resolver,
        connect_deadline_ns,
        tls_handshake_timeout_ns,
    )
    was_reused = conn.reused
    cancel_cb = let conn = conn
        () -> begin
            try
                _set_conn_read_deadline!(conn, Int64(1))
                _set_conn_write_deadline!(conn, Int64(1))
            catch
            end
            try
                _close_conn!(conn)
            catch
            end
        end
    end
    _on_cancel!(request_ctx, cancel_cb)
    try
        canceled(request_ctx) && throw(CanceledError(request_ctx.cancel_message === nothing ? "request canceled" : request_ctx.cancel_message::String))
        _apply_conn_deadline!(conn, request_deadline)
        request_io = _reset_request_buffer!(conn)
        stream = _conn_stream(conn)
        deadline_stream = _RequestDeadlineWriteIO(stream, conn, request)
        has_request_body = _request_has_body(request)
        write_state = has_request_body ? _RequestWriteState(_request_expects_continue(request)) : nothing
        writer_err = Base.RefValue{Union{Nothing,Exception}}(nothing)
        writer_task = nothing
        if has_request_body
            writer_task = Threads.@spawn begin
                try
                    _write_request_streaming!(
                        request_io,
                        deadline_stream,
                        request,
                        plan,
                        write_state,
                        request_deadline,
                    )
                catch err
                    writer_err[] = err isa Exception ? err : ProtocolError("request upload failed")
                    _request_write_allows_close(write_state) || return nothing
                    @try_ignore begin
                        _close_conn!(conn)
                    end
                finally
                    @try_ignore begin
                        body_close!(request.body)
                    end
                    _request_write_mark_done!(write_state)
                end
                return nothing
            end
            if request_deadline == 0
                while !_request_write_head_written_or_done(write_state)
                    IOPoll.timedwait(() -> _request_write_head_written_or_done(write_state), 0.05; pollint=0.001)
                end
            else
                status = IOPoll.timedwait(() -> _request_write_head_written_or_done(write_state), max((request_deadline - Int64(time_ns())) / 1.0e9, 0.0); pollint=0.001)
                status == :timed_out && throw(IOPoll.DeadlineExceededError())
            end
            if _request_write_done(write_state)
                wait(writer_task::Task)
                err = writer_err[]
                err === nothing || throw(err::Exception)
            end
        else
            try
                _write_request_streaming!(request_io, deadline_stream, request, plan)
            finally
                @try_ignore begin
                    body_close!(request.body)
                end
            end
        end
        reader = conn.reader
        _set_conn_read_deadline!(conn, _request_response_header_deadline_ns(request))
        raw_response = _read_transport_incoming_response(reader, transport, conn, request)
        # HTTP/1 informational responses are consumed internally so callers
        # observe the final non-1xx response.
        while (raw_response.head.status >= 100 && raw_response.head.status < 200) && raw_response.head.status != 101
            if _request_write_should_wait_for_continue(write_state) && raw_response.head.status == 100
                _request_write_mark_continue_allowed!(write_state::_RequestWriteState)
            end
            @try_ignore begin
                body_close!(raw_response.rawbody)
            end
            raw_response = _read_transport_incoming_response(reader, transport, conn, request)
        end
        _set_conn_read_deadline!(conn, request_deadline)
        early_final = false
        if _request_write_should_wait_for_continue(write_state) && _request_write_continue_state(write_state::_RequestWriteState) == _REQUEST_WRITE_CONTINUE_PENDING
            _request_write_mark_continue_suppressed!(write_state::_RequestWriteState)
            early_final = true
        end
        if has_request_body && !_request_write_done(write_state)
            early_final = true
            _request_write_request_stop!(write_state::_RequestWriteState)
            _request_write_disallow_close!(write_state::_RequestWriteState)
            _set_conn_write_deadline!(conn, Int64(time_ns()))
        end
        if has_request_body && !early_final
            if request_deadline == 0
                wait(writer_task::Task)
            else
                status = IOPoll.timedwait(() -> istaskdone(writer_task::Task), max((request_deadline - Int64(time_ns())) / 1.0e9, 0.0); pollint=0.001)
                status == :timed_out && throw(IOPoll.DeadlineExceededError())
                wait(writer_task::Task)
            end
        end
        if has_request_body && writer_task !== nothing && istaskdone(writer_task::Task)
            err = writer_err[]
            if err !== nothing && !(early_final && _request_upload_abort_error(err::Exception))
                throw(err::Exception)
            end
        end
        reusable = _response_reusable(raw_response, request)
        early_final && (reusable = false)
        body = _arm_h1_body!(raw_response.rawbody::H1Body, reusable, request_ctx, cancel_cb)
        if _body_immediately_empty(body)
            body_close!(body)
        end
        return _IncomingResponse(raw_response.head, body)
    catch err
        _remove_cancel_callback!(request_ctx, cancel_cb)
        _close_owned_conn!(transport, conn)
        if attempt == 1 && was_reused && retry_template !== nothing && _retryable_reused_conn_error(err)
            return _roundtrip_incoming!(
                transport,
                address,
                _copy_request(retry_template::Request),
                secure,
                server_name,
                proxy_config,
                attempt + 1,
            )
        end
        rethrow(err)
    end
end

"""
    roundtrip!(transport, address, request; secure=false, server_name=nothing) -> Response

Execute a single request through `transport` without the higher-level redirect,
cookie, or retry orchestration provided by `Client`.
"""
function roundtrip!(transport::Transport, address::String, request::Request)
    return _streaming_response(_roundtrip_incoming!(transport, address, request, false, nothing))
end

function roundtrip!(
    transport::Transport,
    address::AbstractString,
    request::Request;
    secure::Bool=false,
    server_name::Union{Nothing,AbstractString}=nothing,
)
    return _streaming_response(_roundtrip_incoming!(transport, address, request, secure, server_name))
end
