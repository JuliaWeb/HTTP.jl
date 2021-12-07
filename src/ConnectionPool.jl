"""
This module provides the [`getconnection`](@ref) function with support for:
- Opening TCP and SSL connections.
- Reusing connections for multiple Request/Response Messages,
- Pipelining Request/Response Messages. i.e. allowing a new Request to be
  sent before previous Responses have been read.

This module defines a [`Connection`](@ref)
struct to manage pipelining and connection reuse and a
[`Transaction`](@ref)`<: IO` struct to manage a single
pipelined request. Methods are provided for `eof`, `readavailable`,
`unsafe_write` and `close`.
This allows the `Transaction` object to act as a proxy for the
`TCPSocket` or `SSLContext` that it wraps.

The [`POOL`](@ref) is used to manage connection pooling. Connections
are identified by their host, port, pipeline limit, whether they require
ssl verification, and whether they are a client or server connection.
If a subsequent request matches these properties of a previous connection
and limits are respected (reuse limit, idle timeout), and it wasn't otherwise
remotely closed, a connection will be reused. Transactions pipeline their
requests and responses concurrently on a Connection by calling `startwrite`
and `closewrite`, with corresponding `startread` and `closeread`.
"""
module ConnectionPool

export Connection, newconnection, getrawstream, inactiveseconds

using ..IOExtras, ..Sockets

import ..@debug, ..@debugshow, ..DEBUG_LEVEL, ..taskid
import ..@require, ..precondition_error, ..@ensure, ..postcondition_error
using MbedTLS: SSLConfig, SSLContext, setup!, associate!, hostname!, handshake!
import NetworkOptions

const default_connection_limit = 8
const default_pipeline_limit = 16
const nolimit = typemax(Int)

include("connectionpools.jl")
using .ConnectionPools

# certain operations, like locking Channels and Conditions
# is only supported in >= 1.3
macro v1_3(expr, elses=nothing)
    esc(quote
        @static if VERSION >= v"1.3"
            $expr
        else
            $elses
        end
    end)
end

@static if VERSION >= v"1.3"
    const Cond = Threads.Condition
else
    const Cond = Condition
end

"""
    Connection{T <: IO}

A `TCPSocket` or `SSLContext` connection to a HTTP `host` and `port`.

Fields:
- `host::String`
- `port::String`, exactly as specified in the URI (i.e. may be empty).
- `idle_timeout`, No. of seconds to maintain connection after last transaction.
- `peerip`, remote IP adress (used for debug/log messages).
- `peerport`, remote TCP port number (used for debug/log messages).
- `localport`, local TCP port number (used for debug messages).
- `io::T`, the `TCPSocket` or `SSLContext.
- `clientconnection::Bool`, whether the Connection was created from client code (as opposed to server code)
- `buffer::IOBuffer`, left over bytes read from the connection after
   the end of a response header (or chunksize). These bytes are usually
   part of the response body.
- `timestamp`, time data was last received.
"""
mutable struct Connection <: IO
    host::String
    port::String
    idle_timeout::Int
    require_ssl_verification::Bool
    peerip::IPAddr # for debugging/logging
    peerport::UInt16 # for debugging/logging
    localport::UInt16 # debug only
    io::IO
    clientconnection::Bool
    buffer::IOBuffer
    timestamp::Float64
    readable::Bool
    writable::Bool
end

"""
    hashconn

Used for "hashing" a Connection object on just the key properties necessary for determining
connection re-useability. That is, when a new request calls `getconnection`, we take the
request parameters of what socket type, the host and port, and if ssl
verification is required, and if an existing Connection was already created with the exact
same parameters, we can re-use it (as long as it's not already being used, obviously).
"""
function hashconn end

hashconn(x::Connection) = hashconn(typeof(x.io), x.host, x.port, x.require_ssl_verification, x.clientconnection)
hashconn(T, host, port, require_ssl_verification, client) = hash(T, hash(host, hash(port, hash(require_ssl_verification, hash(client, UInt(0))))))

Connection(host::AbstractString, port::AbstractString,
           idle_timeout::Int,
           require_ssl_verification::Bool, io::IO, client=true) =
    Connection(host, port,
                  idle_timeout,
                  require_ssl_verification,
                  safe_getpeername(io)..., localport(io),
                  io, client, PipeBuffer(), time(), false, false)

Connection(io; require_ssl_verification::Bool=true) =
    Connection("", "", 0, require_ssl_verification, io, false)

getrawstream(c::Connection) = c.io

inactiveseconds(c::Connection)::Float64 = time() - c.timestamp

Base.unsafe_write(c::Connection, p::Ptr{UInt8}, n::UInt) =
    unsafe_write(c.io, p, n)

Base.isopen(c::Connection) = isopen(c.io)

"""
    flush(c::Connection)

Flush a TCP buffer by toggling the Nagle algorithm off and on again for a socket.
This forces the socket to send whatever data is within its buffer immediately,
rather than waiting 10's of milliseconds for the buffer to fill more.
"""
function Base.flush(c::Connection)
    # Flushing the TCP buffer requires support for `Sockets.nagle()`
    # which was only added in Julia v1.3
    @static if VERSION >= v"1.3"
        sock = tcpsocket(c.io)
        # I don't understand why uninitializd sockets can get here, but they can
        if sock.status ∉ (Base.StatusInit, Base.StatusUninit) && isopen(sock)
            Sockets.nagle(sock, false)
            Sockets.nagle(sock, true)
        end
    end
end

Base.isreadable(c::Connection) = c.readable
Base.iswritable(c::Connection) = c.writable

function Base.eof(c::Connection)
    @require isreadable(c) || !isopen(c)
    if bytesavailable(c) > 0
        return false
    end
    return eof(c.io)
end

Base.bytesavailable(c::Connection) = bytesavailable(c.buffer) +
                                     bytesavailable(c.io)

function Base.read(c::Connection, nb::Int)
    nb = min(nb, bytesavailable(c))
    bytes = Base.StringVector(nb)
    unsafe_read(c, pointer(bytes), nb)
    return bytes
end

function Base.read(c::Connection, ::Type{UInt8})
    if bytesavailable(c.buffer) == 0
        read_to_buffer(c)
    end
    return read(c.buffer, UInt8)
end

function Base.unsafe_read(c::Connection, p::Ptr{UInt8}, n::UInt)
    l = bytesavailable(c.buffer)
    if l > 0
        nb = min(l, n)
        unsafe_read(c.buffer, p, nb)
        p += nb
        n -= nb
        c.timestamp = time()
    end
    if n > 0
        unsafe_read(c.io, p, n)
        c.timestamp = time()
    end
    return nothing
end

function read_to_buffer(c::Connection, sizehint=4096)
    buf = c.buffer

    # Reset the buffer if it is empty.
    if bytesavailable(buf) == 0
        buf.size = 0
        buf.ptr = 1
    end

    # Wait for data.
    if eof(c.io)
        throw(EOFError())
    end

    # Read from stream into buffer.
    n = min(sizehint, bytesavailable(c.io))
    buf = c.buffer
    Base.ensureroom(buf, n)
    unsafe_read(c.io, pointer(buf.data, buf.size + 1), n)
    buf.size += n
end

"""
Read until `find_delimiter(bytes)` returns non-zero.
Return view of bytes up to the delimiter.
"""
function Base.readuntil(c::Connection, f::Function #=Vector{UInt8} -> Int=#,
                                        sizehint=4096)::ByteView
    buf = c.buffer
    if bytesavailable(buf) == 0
        read_to_buffer(c, sizehint)
    end
    while (bytes = readuntil(buf, f)) === nobytes
        read_to_buffer(c, sizehint)
    end
    return bytes
end

"""
    startwrite(::Connection)
"""
function IOExtras.startwrite(c::Connection)
    @require !iswritable(c)
    c.writable = true
    @debug 2 "👁  Start write:$c"
    return
end

"""
    closewrite(::Connection)

Signal that an entire Request Message has been written to the `Connection`.
"""
function IOExtras.closewrite(c::Connection)
    @require iswritable(c)
    c.writable = false
    @debug 2 "🗣  Write done: $c"
    flush(c)
    return
end

"""
    startread(::Connection)
"""
function IOExtras.startread(c::Connection)
    @require !isreadable(c)
    c.timestamp = time()
    c.readable = true
    @debug 2 "👁  Start read: $c"
    return
end

"""
Wait for `c` to receive data or reach EOF.
Close `c` on EOF or if response data arrives when no request was sent.
"""
function monitor_idle_connection(c::Connection)
    if eof(c.io)                                  ;@debug 2 "💀  Closed:     $c"
        close(c.io)
    end
end

"""
    closeread(::Connection)

Signal that an entire Response Message has been read from the `Transaction`.
"""
function IOExtras.closeread(c::Connection)
    @require isreadable(c)
    c.readable = false
    @debug 2 "✉️  Read done:  $c"
    if c.clientconnection
        release(POOL, hashconn(c), c)
        !(c.io isa SSLContext) && @async monitor_idle_connection(c)
    end
    return
end

Base.wait_close(c::Connection) = Base.wait_close(tcpsocket(c.io))

function Base.close(c::Connection)
    if iswritable(c)
        closewrite(c)
    end
    if isreadable(c)
        closeread(c)
    end
    close(c.io)
    if bytesavailable(c) > 0
        purge(c)
    end
    return
end

"""
    purge(::Connection)

Remove unread data from a `Connection`.
"""
function purge(c::Connection)
    @require !isopen(c.io)
    while !eof(c.io)
        readavailable(c.io)
    end
    c.buffer.size = 0
    c.buffer.ptr = 1
    @ensure bytesavailable(c) == 0
end

"""
    closeall()

Close all connections in `pool`.
"""
function closeall()
    ConnectionPools.reset!(POOL)
    return
end

"""
    POOL

Global connection pool keeping track of active connections.
"""
const POOL = Pool(Connection)

"""
    getconnection(type, host, port) -> Connection

Find a reusable `Connection` in the `pool`,
or create a new `Connection` if required.
"""
function newconnection(::Type{T},
                       host::AbstractString,
                       port::AbstractString;
                       connection_limit::Int=default_connection_limit,
                       pipeline_limit::Int=default_pipeline_limit,
                       idle_timeout::Int=typemax(Int64),
                       reuse_limit::Int=nolimit,
                       require_ssl_verification::Bool=NetworkOptions.verify_host(host, "SSL"),
                       kw...)::Connection where {T <: IO}
    return acquire(
            POOL,
            hashconn(T, host, port, require_ssl_verification, true);
            max=connection_limit,
            idle=idle_timeout,
            reuse=reuse_limit) do
        Connection(host, port,
            idle_timeout, require_ssl_verification,
            getconnection(T, host, port;
                require_ssl_verification=require_ssl_verification, kw...)
        )
    end
end

function keepalive!(tcp)
    @debug 2 "setting keepalive on tcp socket"
    err = ccall(:uv_tcp_keepalive, Cint, (Ptr{Nothing}, Cint, Cuint),
                                          tcp.handle, 1, 1)
    err != 0 && error("error setting keepalive on socket")
    return
end

struct ConnectTimeout <: Exception
    host
    port
end

function getconnection(::Type{TCPSocket},
                       host::AbstractString,
                       port::AbstractString;
                       keepalive::Bool=false,
                       connect_timeout::Int=0,
                       readtimeout::Int=0,
                       kw...)::TCPSocket

    p::UInt = isempty(port) ? UInt(80) : parse(UInt, port)

    @debug 2 "TCP connect: $host:$p..."

    addrs = Sockets.getalladdrinfo(host)

    connect_timeout = connect_timeout == 0 && readtimeout > 0 ? readtimeout : connect_timeout

    lasterr = ErrorException("unknown connection error")

    for addr in addrs
        if connect_timeout == 0
            try
                tcp = Sockets.connect(addr, p)
                keepalive && keepalive!(tcp)
                return tcp
            catch err
                lasterr = err
                continue # to next ip addr
            end
        else
            tcp = Sockets.TCPSocket()
            Sockets.connect!(tcp, addr, p)

            timeout = Ref{Bool}(false)
            @async begin
                sleep(connect_timeout)
                if tcp.status == Base.StatusConnecting
                    timeout[] = true
                    tcp.status = Base.StatusClosing
                    ccall(:jl_forceclose_uv, Nothing, (Ptr{Nothing},), tcp.handle)
                    #close(tcp)
                end
            end
            try
                Sockets.wait_connected(tcp)
                keepalive && keepalive!(tcp)
                return tcp
            catch err
                if timeout[]
                    lasterr = ConnectTimeout(host, port)
                else
                    lasterr = err
                end
                continue # to next ip addr
            end
        end
    end
    # If no connetion could be set up, to any address, throw last error
    throw(lasterr)
end

const nosslconfig = SSLConfig()
default_sslconfig = nothing
noverify_sslconfig = nothing

function global_sslconfig(require_ssl_verification::Bool)::SSLConfig
    global default_sslconfig
    global noverify_sslconfig
    if default_sslconfig === nothing
        default_sslconfig = SSLConfig(true)
        noverify_sslconfig = SSLConfig(false)
    end
    return require_ssl_verification ? default_sslconfig : noverify_sslconfig
end

function getconnection(::Type{SSLContext},
                       host::AbstractString,
                       port::AbstractString;
                       kw...)::SSLContext

    port = isempty(port) ? "443" : port
    @debug 2 "SSL connect: $host:$port..."
    tcp = getconnection(TCPSocket, host, port; kw...)
    return sslconnection(tcp, host; kw...)
end

function sslconnection(tcp::TCPSocket, host::AbstractString;
                       require_ssl_verification::Bool=NetworkOptions.verify_host(host, "SSL"),
                       sslconfig::SSLConfig=nosslconfig,
                       kw...)::SSLContext

    if sslconfig === nosslconfig
        sslconfig = global_sslconfig(require_ssl_verification)
    end

    io = SSLContext()
    setup!(io, sslconfig)
    associate!(io, tcp)
    hostname!(io, host)
    handshake!(io)
    return io
end

function sslupgrade(c::Connection,
                    host::AbstractString;
                    require_ssl_verification::Bool=NetworkOptions.verify_host(host, "SSL"),
                    kw...)::Connection
    # first we release the original connection, but we don't want it to be
    # reused in the pool, because we're hijacking the TCPSocket
    release(POOL, hashconn(c), c; return_for_reuse=false)
    # now we hijack the TCPSocket and upgrade to SSLContext
    tls = sslconnection(c.io, host;
                        require_ssl_verification=require_ssl_verification,
                        kw...)
    conn = Connection(host, "", 0, require_ssl_verification, tls)
    return acquire(() -> conn, POOL, hashconn(conn))
end

function Base.show(io::IO, c::Connection)
    nwaiting = applicable(tcpsocket, c.io) ? bytesavailable(tcpsocket(c.io)) : 0
    print(
        io,
        tcpstatus(c), " ",
        "$(lpad(round(Int, time() - c.timestamp), 3))s ",
        c.host, ":",
        c.port != "" ? c.port : Int(c.peerport), ":", Int(c.localport),
        bytesavailable(c.buffer) > 0 ?
            " $(bytesavailable(c.buffer))-byte excess" : "",
        nwaiting > 0 ? " $nwaiting bytes waiting" : "",
        DEBUG_LEVEL[] > 1 && applicable(tcpsocket, c.io) ?
            " $(Base._fd(tcpsocket(c.io)))" : "")
end

function tcpstatus(c::Connection)
    if !applicable(tcpsocket, c.io)
        return ""
    end
    s = Base.uv_status_string(tcpsocket(c.io))
        if s == "connecting" return "🔜🔗"
    elseif s == "open"       return "🔗 "
    elseif s == "active"     return "🔁 "
    elseif s == "paused"     return "⏸ "
    elseif s == "closing"    return "🔜💀"
    elseif s == "closed"     return "💀 "
    else
        return s
    end
end

end # module ConnectionPool
