# HTTP client transport, connection pooling, and low-level HTTP/1 roundtrip APIs.
export Transport
export ManagedBody
export roundtrip!
export close_idle_connections!
export idle_connection_count

using Base64
using CodecZlib
using Reseau.TCP
using Reseau.HostResolvers
using Reseau.TLS

const _CONN_READER_DEFAULT_BUFFER_BYTES = 16 * 1024

mutable struct _ConnReader{C} <: IO
    conn::C
    buf::Vector{UInt8}
    next::Int
    stop::Int
end

"""
    _ConnReader(conn; buffer_bytes=16*1024)

Buffered `IO` adapter layered over `TCP.Conn` or `TLS.Conn`.

HTTP/1 parsing wants a byte-oriented reader with a small amount of lookahead so
it can parse lines and then continue reading bodies from the same transport.
This type provides that without forcing the transport types themselves to own
HTTP-specific buffering policy.
"""
function _ConnReader(conn::C; buffer_bytes::Integer=_CONN_READER_DEFAULT_BUFFER_BYTES) where {C}
    buffer_bytes > 0 || throw(ArgumentError("buffer_bytes must be > 0"))
    return _ConnReader{C}(conn, Vector{UInt8}(undef, Int(buffer_bytes)), 1, 0)
end

@inline function _conn_reader_available(reader::_ConnReader)::Int
    reader.next > reader.stop && return 0
    return reader.stop - reader.next + 1
end

@inline function _fill_conn_reader!(reader::_ConnReader)::Int
    n = readbytes!(reader.conn, reader.buf; all=false)
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

const _PooledConnReader = Union{_ConnReader{TCP.Conn},_ConnReader{TLS.Conn}}

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
    reader::_PooledConnReader
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
    host_resolver::HostResolvers.HostResolver
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

"""
    ManagedBody

Response body wrapper that returns/tears down pooled connections once the body
is fully consumed or closed.

If the caller drains the body to EOF, `ManagedBody` returns the underlying
connection to the idle pool when it is safe to do so. If the body is abandoned
early or an error occurs, the connection is closed instead so the next request
does not observe leftover bytes.
"""
mutable struct ManagedBody{B<:AbstractBody} <: AbstractBody
    inner::B
    transport::Transport
    conn::Conn
    reusable::Bool
    @atomic saw_eof::Bool
    @atomic released::Bool
end

function Transport(;
    host_resolver::HostResolvers.HostResolver=HostResolvers.HostResolver(),
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

function _close_conn!(conn::Conn)::Bool
    if _conn_closed(conn)
        return false
    end
    @atomic :release conn.closed = true
    if conn.secure
        if conn.tls !== nothing
            try
                TLS.close(conn.tls::TLS.Conn)
            catch
            end
        end
    else
        if conn.tcp !== nothing
            try
                TCP.close(conn.tcp::TCP.Conn)
            catch
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
        timedwait(() -> (@atomic :acquire waiter.state) != _CONN_WAITER_WAITING, timeout_s; pollint=0.001)
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

function _effective_tls_config(transport::Transport, address::String, server_name::Union{Nothing,String})::TLS.Config
    sni = server_name === nothing ? _host_for_sni(address) : server_name
    cfg = transport.tls_config
    if cfg === nothing
        return TLS.Config(server_name=sni)
    end
    if cfg.server_name !== nothing
        return cfg
    end
    return TLS.Config(
        server_name=sni,
        verify_peer=cfg.verify_peer,
        client_auth=cfg.client_auth,
        cert_file=cfg.cert_file,
        key_file=cfg.key_file,
        ca_file=cfg.ca_file,
        client_ca_file=cfg.client_ca_file,
        alpn_protocols=copy(cfg.alpn_protocols),
        handshake_timeout_ns=cfg.handshake_timeout_ns,
        min_version=cfg.min_version,
        max_version=cfg.max_version,
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

function _write_request_streaming!(
    request_io::IOBuffer,
    stream,
    request::Request;
    wire_target::Union{Nothing,AbstractString}=nothing,
    proxy_authorization::Union{Nothing,AbstractString}=nothing,
)
    if request.content_length >= 0 && request.body isa BytesBody && !headercontains(request.headers, "Transfer-Encoding", "chunked")
        _write_request_head!(request_io, request; wire_target=wire_target, proxy_authorization=proxy_authorization)
        _write_request_bytes!(stream, request_io)
        _write_exact_bytes_body!(stream, request.body::BytesBody, request.content_length)
        return nothing
    end
    write_request!(request_io, request; wire_target=wire_target, proxy_authorization=proxy_authorization)
    _write_request_bytes!(stream, request_io)
    return nothing
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
    try
        body_close!(response.rawbody)
    catch
    end
    response.head.status == 200 || throw(ProtocolError("proxy CONNECT failed with status $(response.head.status)"))
    return nothing
end

function _new_conn!(
    transport::Transport,
    plan::_ProxyPlan,
    address::String;
    secure::Bool,
    server_name::Union{Nothing,String},
    deadline_ns::Int64=Int64(0),
)::Conn
    tcp = TCP.connect(transport.host_resolver, "tcp", plan.first_hop_address)
    if plan.mode == _ProxyPlanMode.HTTP_TUNNEL
        proxy = plan.proxy
        proxy === nothing && throw(ProtocolError("proxy CONNECT tunnel is missing proxy config"))
        _perform_http_connect_tunnel!(tcp, proxy::_ProxyTarget, address, deadline_ns)
    end
    if secure
        cfg = _effective_tls_config(transport, address, server_name)
        tls = TLS.client(tcp, cfg)
        TLS.handshake!(tls)
        return Conn(plan.pool_key, plan.first_hop_address, true, tcp, tls, _ConnReader(tls), IOBuffer(), false, false, time_ns())
    end
    return Conn(plan.pool_key, plan.first_hop_address, false, tcp, nothing, _ConnReader(tcp), IOBuffer(), false, false, time_ns())
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
    address::String;
    secure::Bool,
    server_name::Union{Nothing,String},
    deadline_ns::Int64=Int64(0),
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
                return _new_conn!(transport, plan, address; secure=secure, server_name=server_name, deadline_ns=deadline_ns)
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
        result = _wait_for_conn!(transport, waiter::_ConnWaiter, deadline_ns)
        if result === :dial
            try
                return _new_conn!(transport, plan, address; secure=secure, server_name=server_name, deadline_ns=deadline_ns)
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
    close_idle_connections!(transport)

Close and discard all currently idle pooled connections. Active in-flight
requests are unaffected. Returns `nothing`.
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

function Base.read(reader::_ConnReader{C}, ::Type{UInt8}) where {C}
    if _conn_reader_available(reader) > 0
        b = @inbounds reader.buf[reader.next]
        reader.next += 1
        return b
    end
    n = _fill_conn_reader!(reader)
    n == 0 && throw(EOFError())
    reader.next = 2
    return @inbounds reader.buf[1]
end

function Base.readbytes!(reader::_ConnReader{C}, dst::Vector{UInt8}, nb::Integer=length(dst)) where {C}
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

@inline function _read_u8(reader::_ConnReader{C})::UInt8 where {C}
    if _conn_reader_available(reader) > 0
        b = @inbounds reader.buf[reader.next]
        reader.next += 1
        return b
    end
    n = _fill_conn_reader!(reader)
    n == 0 && throw(ParseError("unexpected EOF while reading HTTP/1 data"))
    reader.next = 2
    return @inbounds reader.buf[1]
end

function _readline_crlf(reader::_ConnReader{C}, max_line_bytes::Integer)::String where {C}
    max_line_bytes <= 0 && throw(ArgumentError("max_line_bytes must be > 0"))
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
            length(bytes) + segment_len > max_line_bytes && throw(ProtocolError("HTTP/1 line exceeds configured max_line_bytes"))
            append!(bytes, @view(reader.buf[start:stop]))
            reader.next = stop + 1
            continue
        end
        segment_len = nl_idx - start + 1
        length(bytes) + segment_len > max_line_bytes && throw(ProtocolError("HTTP/1 line exceeds configured max_line_bytes"))
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

@inline function _response_reusable(response::_IncomingResponse, request::Request)::Bool
    response.head.close && return false
    request.close && return false
    headercontains(response.head.headers, "Connection", "close") && return false
    response.rawbody isa EOFBody && return false
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

function _release_managed!(body::ManagedBody)
    was_released = @atomic :acquire body.released
    was_released && return nothing
    @atomic :release body.released = true
    if body.reusable
        _put_idle_conn!(body.transport, body.conn)
    else
        _close_owned_conn!(body.transport, body.conn)
    end
    return nothing
end

function body_closed(body::ManagedBody)::Bool
    return @atomic :acquire body.released
end

function body_close!(body::ManagedBody)
    if !(@atomic :acquire body.saw_eof)
        body.reusable = false
    end
    body_close!(body.inner)
    _release_managed!(body)
    return nothing
end

function body_read!(body::ManagedBody, dst::Vector{UInt8})::Int
    try
        n = body_read!(body.inner, dst)
        if n == 0
            @atomic :release body.saw_eof = true
            _release_managed!(body)
        end
        return n
    catch
        body.reusable = false
        _release_managed!(body)
        rethrow()
    end
end

"""
    roundtrip!(transport, address, request; secure=false, server_name=nothing)

Execute one HTTP/1 request/response exchange through `transport`.

This is the low-level HTTP/1 path used by the higher-level client APIs. It
returns a `Response`, potentially wrapping the body in `ManagedBody` so the
connection can be recycled when the caller finishes consuming it.

Throws parser, protocol, transport, TLS, and timeout exceptions depending on
where the exchange fails.
"""
function _roundtrip_incoming!(
    transport::Transport,
    address::AbstractString,
    request::Request;
    secure::Bool=false,
    server_name::Union{Nothing,AbstractString}=nothing,
    proxy_config::ProxyConfig=transport.proxy,
)
    request_deadline = _request_deadline_ns(request)
    retry_template = _retryable_request(request) ? _copy_request(request) : nothing
    attempt = 1
    current_request = request
    while true
        plan = _proxy_plan(proxy_config, secure, String(address))
        conn = _acquire_conn!(
            transport,
            plan,
            String(address);
            secure=secure,
            server_name=server_name === nothing ? nothing : String(server_name),
            deadline_ns=request_deadline,
        )
        was_reused = conn.reused
        try
            _apply_conn_deadline!(conn, request_deadline)
            request_io = _reset_request_buffer!(conn)
            stream = _conn_stream(conn)
            try
                wire_target = plan.mode == _ProxyPlanMode.HTTP_FORWARD ? _request_url(false, String(address), current_request.target) : nothing
                proxy_auth = plan.mode == _ProxyPlanMode.HTTP_FORWARD && plan.proxy !== nothing ? (plan.proxy::_ProxyTarget).authorization : nothing
                _write_request_streaming!(request_io, stream, current_request; wire_target=wire_target, proxy_authorization=proxy_auth)
            finally
                try
                    body_close!(current_request.body)
                catch
                end
            end
            reader = conn.reader
            raw_response = _read_incoming_response(reader, current_request)
            # HTTP/1 informational responses are consumed internally so callers
            # observe the final non-1xx response.
            while (raw_response.head.status >= 100 && raw_response.head.status < 200) && raw_response.head.status != 101
                try
                    body_close!(raw_response.rawbody)
                catch
                end
                raw_response = _read_incoming_response(reader, current_request)
            end
            reusable = _response_reusable(raw_response, current_request)
            if raw_response.rawbody isa EmptyBody
                if reusable
                    _put_idle_conn!(transport, conn)
                else
                    _close_owned_conn!(transport, conn)
                end
                return raw_response
            end
            managed = ManagedBody(raw_response.rawbody, transport, conn, reusable, false, false)
            return _IncomingResponse(
                raw_response.head,
                managed,
            )
        catch err
            _close_owned_conn!(transport, conn)
            if attempt == 1 && was_reused && retry_template !== nothing && _retryable_reused_conn_error(err)
                current_request = _copy_request(retry_template::Request)
                attempt = 2
                continue
            end
            rethrow(err)
        end
    end
end

"""
    roundtrip!(transport, address, request; secure=false, server_name=nothing) -> Response

Execute a single request through `transport` without the higher-level redirect,
cookie, or retry orchestration provided by `Client`.
"""
function roundtrip!(
    transport::Transport,
    address::AbstractString,
    request::Request;
    secure::Bool=false,
    server_name::Union{Nothing,AbstractString}=nothing,
)
    return _streaming_response(_roundtrip_incoming!(transport, address, request; secure=secure, server_name=server_name))
end
