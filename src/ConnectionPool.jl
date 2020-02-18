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

The [`pool`](@ref) is a collection of open
`Connection`s.  The `request` function calls `getconnection` to
retrieve a connection from the `pool`.  When the `request` function
has written a Request Message it calls `closewrite` to signal that
the `Connection` can be reused for writing (to send the next Request).
When the `request` function has read the Response Message it calls
`closeread` to signal that the `Connection` can be reused for
reading.
"""
module ConnectionPool

export Connection, Transaction,
       getconnection, getrawstream, inactiveseconds

using ..IOExtras, ..Sockets

import ..@debug, ..DEBUG_LEVEL, ..taskid
import ..@require, ..precondition_error, ..@ensure, ..postcondition_error
using MbedTLS: SSLConfig, SSLContext, setup!, associate!, hostname!, handshake!

const default_connection_limit = 8
const default_pipeline_limit = 16
const nolimit = typemax(Int)

"""
    Connection{T <: IO}

A `TCPSocket` or `SSLContext` connection to a HTTP `host` and `port`.

Fields:
- `host::String`
- `port::String`, exactly as specified in the URI (i.e. may be empty).
- `pipeline_limit`, number of requests to send before waiting for responses.
- `idle_timeout`, No. of seconds to maintain connection after last transaction.
- `peerport`, remote TCP port number (used for debug messages).
- `localport`, local TCP port number (used for debug messages).
- `io::T`, the `TCPSocket` or `SSLContext.
- `buffer::IOBuffer`, left over bytes read from the connection after
   the end of a response header (or chunksize). These bytes are usually
   part of the response body.
- `sequence`, number of most recent `Transaction`.
- `writecount`, number of Messages that have been written.
- `writelock`, lock that a Transaction will own between `startwrite` and `closewrite`
- `readcount`, number of Messages that have been read.
- `readlock`, lock that a Transaction will own between `startread` and `closeread`
- `timestamp`, time data was last received.
"""
mutable struct Connection{T <: IO}
    host::String
    port::String
    pipeline_limit::Int
    idle_timeout::Int
    require_ssl_verification::Bool
    peerport::UInt16 # debug only
    localport::UInt16 # debug only
    io::T
    buffer::IOBuffer
    sequence::Threads.Atomic{Int}
    writecount::Threads.Atomic{Int}
    writelock::Channel{ReentrantLock}
    readcount::Threads.Atomic{Int}
    readlock::Channel{ReentrantLock}
    timestamp::Float64
end

"""
    Transaction

A single pipelined HTTP Request/Response transaction`.

Fields:
 - `c`, the shared [`Connection`](@ref) used for this `Transaction`.
 - `sequence::Int`, identifies this `Transaction` among the others that share `c`.
"""
struct Transaction{T <: IO} <: IO
    c::Connection{T}
    sequence::Int
    writelock::Channel{ReentrantLock}
    readlock::Channel{ReentrantLock}
end

function channellock()
    c = Channel{ReentrantLock}(1)
    put!(c, ReentrantLock())
    return c
end

aint(x=0) = Threads.Atomic{Int}(x)

Connection(host::AbstractString, port::AbstractString,
           pipeline_limit::Int, idle_timeout::Int,
           require_ssl_verification::Bool, io::T) where T <: IO =
    Connection{T}(host, port,
                  pipeline_limit, idle_timeout,
                  require_ssl_verification,
                  peerport(io), localport(io),
                  io, PipeBuffer(),
                  aint(-1),
                  aint(0), channellock(),
                  aint(0), channellock(),
                  time())

Connection(io; require_ssl_verification::Bool=true) =
    Connection("", "", default_pipeline_limit, 0, require_ssl_verification, io)

Transaction(c::Connection{T}) where T <: IO =
    Transaction{T}(c, (Threads.atomic_add!(c.sequence, 1); c.sequence[]), Channel{ReentrantLock}(1), Channel{ReentrantLock}(1))

function client_transaction(c)
    t = Transaction(c)
    startwrite(t)
    return t
end

getrawstream(t::Transaction) = t.c.io

writelocked(c::Connection) = !isready(c.writelock)
readlocked(c::Connection) = !isready(c.readlock)

writelocked(t::Transaction) = isready(t.writelock)
readlocked(t::Transaction) = isready(t.readlock)

inactiveseconds(t::Transaction) = inactiveseconds(t.c)

function inactiveseconds(c::Connection)::Float64
    if writelocked(c) || readlocked(c)
        return 0.0
    end
    return time() - c.timestamp
end

Base.unsafe_write(t::Transaction, p::Ptr{UInt8}, n::UInt) =
    unsafe_write(t.c.io, p, n)

Base.isopen(c::Connection) = isopen(c.io)

Base.isopen(t::Transaction) = isopen(t.c) &&
                              t.c.readcount[] <= t.sequence &&
                              t.c.writecount[] <= t.sequence

"""
Is `c` currently in use or expecting a response to request already sent?
"""
isbusy(c::Connection) = isopen(c) && (writelocked(c) || readlocked(c))

function Base.eof(t::Transaction)
    @require isreadable(t) || !isopen(t)
    if bytesavailable(t) > 0
        return false
    end             ;@debug 4 "eof(::Transaction) -> eof($(typeof(t.c.io))): $t"
    return eof(t.c.io)
end

Base.bytesavailable(t::Transaction) = bytesavailable(t.c)
Base.bytesavailable(c::Connection) = bytesavailable(c.buffer) +
                                     bytesavailable(c.io)

Base.isreadable(t::Transaction) = readlocked(t) && t.c.readcount[] == t.sequence

Base.iswritable(t::Transaction) = writelocked(t) && t.c.writecount[] == t.sequence

function Base.read(t::Transaction, nb::Int)
    nb = min(nb, bytesavailable(t))
    bytes = Base.StringVector(nb)
    unsafe_read(t, pointer(bytes), nb)
    return bytes
end

function Base.read(t::Transaction, ::Type{UInt8})
    if bytesavailable(t.c.buffer) == 0
        read_to_buffer(t)
    end
    return read(t.c.buffer, UInt8)
end

function Base.unsafe_read(t::Transaction, p::Ptr{UInt8}, n::UInt)
    l = bytesavailable(t.c.buffer)
    if l > 0
        nb = min(l,n)
        unsafe_read(t.c.buffer, p, nb)
        p += nb
        n -= nb
        @debug 4 "↩️  read $nb-bytes from buffer."
    end
    if n > 0
        unsafe_read(t.c.io, p, n)
        @debug 4 "⬅️  read $n-bytes from $(typeof(t.c.io))"
    end
    return nothing
end

function read_to_buffer(t::Transaction, sizehint=4096)

    buf = t.c.buffer

    # Reset the buffer if it is empty.
    if bytesavailable(buf) == 0
        buf.size = 0
        buf.ptr = 1
    end

    # Wait for data.
    if eof(t.c.io)
        throw(EOFError())
    end

    # Read from stream into buffer.
    n = min(sizehint, bytesavailable(t.c.io))
    buf = t.c.buffer
    Base.ensureroom(buf, n)
    unsafe_read(t.c.io, pointer(buf.data, buf.size + 1), n)
    buf.size += n
end

"""
Read until `find_delimiter(bytes)` returns non-zero.
Return view of bytes up to the delimiter.
"""
function Base.readuntil(t::Transaction, f::Function #=Vector{UInt8} -> Int=#,
                                        sizehint=4096)::ByteView
    buf = t.c.buffer
    if bytesavailable(buf) == 0
        read_to_buffer(t, sizehint)
    end
    while (bytes = readuntil(buf, f)) === nobytes
        read_to_buffer(t, sizehint)
    end
    return bytes
end

"""
    startwrite(::Transaction)

Wait for prior pending writes to complete.
"""
function IOExtras.startwrite(t::Transaction)
    @require !iswritable(t)                     ;t.c.writecount[] != t.sequence &&
                                                   @debug 1 "⏳  Wait write: $t"
    @debug 1 "taking connection writelock: $t"
    x = take!(t.c.writelock)
    @debug 1 "putting transaction writelock: $t"
    put!(t.writelock, x)     ;@debug 1 "👁  Start write:$t"
    @ensure iswritable(t)
    return
end

"""
    closewrite(::Transaction)

Signal that an entire Request Message has been written to the `Transaction`.
"""
function IOExtras.closewrite(t::Transaction)
    @require iswritable(t)
    @debug 1 "taking transaction writelock: $t"
    l = take!(t.writelock)
    Threads.atomic_add!(t.c.writecount, 1)                           ;@debug 1 "🗣  Write done: $t"
    @debug 1 "putting connection writelock: $t"
    put!(t.c.writelock, l)
    @ensure !iswritable(t)
    return
end

"""
    startread(::Transaction)

Wait for prior pending reads to complete.
"""
function IOExtras.startread(t::Transaction)
    @require !isreadable(t)                      ;t.c.readcount[] != t.sequence &&
                                                   @debug 1 "⏳  Wait read:  $t"
    t.c.timestamp = time()
    @debug 1 "taking connection readlock: $t"
    x = take!(t.c.readlock)
    @debug 1 "putting transaction readlock: $t"
    put!(t.readlock, x)        ;@debug 1 "👁  Start read: $t"
    @ensure isreadable(t)
    return
end

"""
    closeread(::Transaction)

Signal that an entire Response Message has been read from the `Transaction`.

Increment `readcount` and wake up tasks waiting in `startread`.
"""
function IOExtras.closeread(t::Transaction)
    @require isreadable(t)
    @debug 1 "taking transaction readlock: $t"
    l = take!(t.readlock)
    Threads.atomic_add!(t.c.readcount, 1)         ;@debug 1 "✉️  Read done:  $t"
    @debug 1 "putting connection readlock: $t"
    put!(t.c.readlock, l)
    @ensure !isreadable(t)
    if isready(connectionclose)
        @debug 1 "putting connectionclose: $t"
        put!(connectionclose, nothing)
    end

    if !isbusy(t.c)
        @async monitor_idle_connection(t.c)
    end
    return
end

"""
Wait for `c` to receive data or reach EOF.
Close `c` on EOF or if response data arrives when no request was sent.
"""
function monitor_idle_connection(c::Connection)
    if eof(c.io)                                  ;@debug 2 "💀  Closed:     $c"
        close(c.io)
    elseif !isbusy(c)                             ;@debug 1 "😈  Idle RX!!:  $c"
        close(c.io)
    end
end

function monitor_idle_connection(c::Connection{SSLContext})
    # MbedTLS.jl monitors idle connections for TLS close_notify messages.
    # https://github.com/JuliaWeb/MbedTLS.jl/pull/145
end

Base.wait_close(t::Transaction) = Base.wait_close(tcpsocket(t.c.io))

function Base.close(t::Transaction)
    close(t.c)
    if iswritable(t)
        println("close transaction")
        closewrite(t)
    end
    if isreadable(t)
        closeread(t)
    end
    return
end

function Base.close(c::Connection)
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

function initializepool()
    pool = Channel{Vector{Connection}}(1)
    put!(pool, Connection[])
    return pool
end

function withpool(f)
    conns = take!(pool)
    x = f(conns)
    put!(pool, conns)
    return x
end

"""
The `pool` is a collection of open `Connection`s.  The `request`
function calls `getconnection` to retrieve a connection from the
`pool`.  When the `request` function has written a Request Message
it calls `closewrite` to signal that the `Connection` can be reused
for writing (to send the next Request). When the `request` function
has read the Response Message it calls `closeread` to signal that
the `Connection` can be reused for reading.
"""
const pool = initializepool()
const connectionclose = Channel(0)

"""
    closeall()

Close all connections in `pool`.
"""
function closeall()
    withpool() do conns
        foreach(close, conns)
        empty!(conns)
    end
    isready(connectionclose) && put!(connectionclose, nothing)
    return
end

"""
    findwritable(type, host, port) -> Vector{Connection}

Find `Connections` in the `pool` that are ready for writing.
"""
function findwritable(T::Type,
                      host::AbstractString,
                      port::AbstractString,
                      pipeline_limit::Int,
                      require_ssl_verification::Bool,
                      reuse_limit::Int,
                      conns)

    filter(c->(!writelocked(c) &&
               typeof(c.io) == T &&
               c.host == host &&
               c.port == port &&
               c.pipeline_limit == pipeline_limit &&
               c.require_ssl_verification == require_ssl_verification &&
               c.writecount[] < reuse_limit &&
               c.writecount[] - c.readcount[] < (pipeline_limit + 1) &&
               isopen(c.io)), conns)
end

"""
    findoverused(type, host, port, reuse_limit) -> Vector{Connection}

Find `Connections` in the `pool` that are over the reuse limit
and have no more active readers.
"""
function findoverused(T::Type,
                      host::AbstractString,
                      port::AbstractString,
                      reuse_limit::Int,
                      conns)

    filter(c->(typeof(c.io) == T &&
               c.host == host &&
               c.port == port &&
               c.readcount[] >= reuse_limit &&
               !readlocked(c) &&
               isopen(c.io)), conns)
end

"""
    findall(type, host, port) -> Vector{Connection}

Find all `Connections` in the `pool` for `host` and `port`.
"""
function findall(T::Type,
                 host::AbstractString,
                 port::AbstractString,
                 pipeline_limit::Int,
                 require_ssl_verification::Bool,
                 conns)

    filter(c->(typeof(c.io) == T &&
               c.host == host &&
               c.port == port &&
               c.pipeline_limit == pipeline_limit &&
               c.require_ssl_verification == require_ssl_verification &&
               isopen(c.io)), conns)
end

"""
    purge()

Remove closed connections from `pool`.
"""
function purge!(conns)
    for c in conns
        if c.idle_timeout > 0 &&
          !readlocked(c) &&
          !writelocked(c) &&
           time() - c.timestamp > c.idle_timeout

            close(c.io)                       ;@debug 1 "⌛️  Timeout:        $c"
        end
    end

    isdeletable(c) = !isopen(c.io) && (@debug 1 "🗑  Deleted:        $c"; true)
    deleteat!(conns, map(isdeletable, conns))
    return
end

"""
    getconnection(type, host, port) -> Connection

Find a reusable `Connection` in the `pool`,
or create a new `Connection` if required.
"""
function getconnection(::Type{Transaction{T}},
                       host::AbstractString,
                       port::AbstractString;
                       connection_limit::Int=default_connection_limit,
                       pipeline_limit::Int=default_pipeline_limit,
                       idle_timeout::Int=0,
                       reuse_limit::Int=nolimit,
                       require_ssl_verification::Bool=true,
                       kw...)::Transaction{T} where T <: IO

    while true
        conn = withpool() do conns
            # Close connections that have reached the reuse limit...
            if reuse_limit != nolimit
                foreach(close, findoverused(T, host, port, reuse_limit, conns))
            end

            # Remove closed connections from `pool`...
            purge!(conns)

            # Try to find a connection with no active readers or writers...
            writable = findwritable(T, host, port, pipeline_limit,
                                                    require_ssl_verification,
                                                    reuse_limit, conns)
            idle = filter(c->!readlocked(c), writable)
            if !isempty(idle)
                c = rand(idle)                 ;@debug 2 "♻️  Idle:           $c"
                return client_transaction(c)
            end

            # If there are not too many connections to this host:port,
            # create a new connection...
            busy = findall(T, host, port, pipeline_limit,
                                            require_ssl_verification, conns)
            if length(busy) < connection_limit
                io = getconnection(T, host, port; require_ssl_verification=
                                                    require_ssl_verification,
                                                    kw...)
                c = Connection(host, port,
                                pipeline_limit, idle_timeout,
                                require_ssl_verification,
                                io)
                push!(conns, c)                ;@debug 1 "🔗  New:            $c"
                return client_transaction(c)
            end

            # Share a connection that has active readers...
            if !isempty(writable)
                c = rand(writable)             ;@debug 2 "⇆  Shared:         $c"
                return client_transaction(c)
            end
        end
        conn !== nothing && return conn
        take!(connectionclose)
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
                       kw...)::TCPSocket

    p::UInt = isempty(port) ? UInt(80) : parse(UInt, port)

    @debug 2 "TCP connect: $host:$p..."

    if connect_timeout == 0
        tcp = Sockets.connect(Sockets.getalladdrinfo(host)[1], p)
        keepalive && keepalive!(tcp)
        return tcp
    end

    tcp = Sockets.TCPSocket()
    Base.connect!(tcp, Sockets.getaddrinfo(host), p)

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
        Base.wait_connected(tcp)
    catch e
        if timeout[]
            throw(ConnectTimeout(host, port))
        end
        rethrow(e)
    end

    keepalive && keepalive!(tcp)
    return tcp
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
                       require_ssl_verification::Bool=true,
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

function sslupgrade(t::Transaction{TCPSocket},
                    host::AbstractString;
                    require_ssl_verification::Bool=true,
                    kw...)::Transaction{SSLContext}
    tls = sslconnection(t.c.io, host;
                        require_ssl_verification=require_ssl_verification,
                        kw...)
    c = Connection(tls; require_ssl_verification=require_ssl_verification)
    return client_transaction(c)
end

function Base.show(io::IO, c::Connection)
    nwaiting = applicable(tcpsocket, c.io) ? bytesavailable(tcpsocket(c.io)) : 0
    print(
        io,
        tcpstatus(c), " ",
        lpad(c.writecount[], 3),"↑", writelocked(c) ? "🔒  " : "   ",
        lpad(c.readcount[], 3), "↓", readlocked(c) ? "🔒 " : "  ",
        "$(lpad(round(Int, time() - c.timestamp), 3))s ",
        c.host, ":",
        c.port != "" ? c.port : Int(c.peerport), ":", Int(c.localport),
        " ≣", c.pipeline_limit,
        bytesavailable(c.buffer) > 0 ?
            " $(bytesavailable(c.buffer))-byte excess" : "",
        nwaiting > 0 ? " $nwaiting bytes waiting" : "",
        DEBUG_LEVEL[] > 1 && applicable(tcpsocket, c.io) ?
            " $(Base._fd(tcpsocket(c.io)))" : "")
end

Base.show(io::IO, t::Transaction) = print(io, "T$(rpad(t.sequence,2)) ", t.c)

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

function showpool(io::IO)
    withpool() do conns
        println(io, "ConnectionPool[")
        for c in conns
            println(io, "   $c")
        end
        println(io, "]\n")
    end
end

function showpoolhtml(io::IO)
    withpool() do conns
        println(io, "<table>")
        for c in conns
            print(io, "<tr>")
            for x in split("$c")
                print(io, "<td>$x</td>")
            end
            println(io, "<tr>")
        end
        println(io, "</table>")
    end
end

end # module ConnectionPool
