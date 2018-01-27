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
       getconnection, getparser, getrawstream, inactiveseconds

using ..IOExtras

import ..bytesavailable
import ..@debug, ..@debugshow, ..DEBUG_LEVEL, ..taskid
import ..@require, ..precondition_error, ..@ensure, ..postcondition_error
using MbedTLS: SSLConfig, SSLContext, setup!, associate!, hostname!, handshake!

import ..Parser


const default_connection_limit = 8
const default_pipeline_limit = 16
const nolimit = typemax(Int)

const nobytes = view(UInt8[], 1:0)
const ByteView = typeof(nobytes)
byteview(bytes::ByteView) = bytes
byteview(bytes)::ByteView = view(bytes, 1:length(bytes))


"""
    Connection{T <: IO}

A `TCPSocket` or `SSLContext` connection to a HTTP `host` and `port`.

Fields:
- `host::String`
- `port::String`, exactly as specified in the URI (i.e. may be empty).
- `pipeline_limit`, number of requests to send before waiting for responses.
- `peerport`, remote TCP port number (used for debug messages).
- `localport`, local TCP port number (used for debug messages).
- `io::T`, the `TCPSocket` or `SSLContext.
- `excess::ByteView`, left over bytes read from the connection after
   the end of a response message. These bytes are probably the start of the
   next response message.
- `sequence`, number of most recent `Transaction`.
- `writecount`, number of Messages that have been written.
- `writedone`, signal that `writecount` was incremented.
- `readcount`, number of Messages that have been read.
- `readdone`, signal that `readcount` was incremented.
- `timestamp`, time data was last recieved.
- `parser::Parser`, reuse a `Parser` when this `Connection` is reused.
"""

mutable struct Connection{T <: IO}
    host::String
    port::String
    pipeline_limit::Int
    peerport::UInt16
    localport::UInt16
    io::T
    excess::ByteView
    sequence::Int
    writecount::Int
    writebusy::Bool
    writedone::Condition
    readcount::Int
    readbusy::Bool
    readdone::Condition
    timestamp::Float64
    parser::Parser
end


"""
A single pipelined HTTP Request/Response transaction`.

Fields:
 - `c`, the shared [`Connection`](@ref) used for this `Transaction`.
 - `sequence::Int`, identifies this `Transaction` among the others that share `c`.
"""

struct Transaction{T <: IO} <: IO
    c::Connection{T}
    sequence::Int
end


Connection(host::AbstractString, port::AbstractString,
           pipeline_limit::Int, io::T) where T <: IO =
    Connection{T}(host, port, pipeline_limit,
                  peerport(io), localport(io),
                  io, nobytes,
                  -1,
                  0, false, Condition(),
                  0, false, Condition(),
                  0, Parser())

Transaction(c::Connection{T}) where T <: IO =
    Transaction{T}(c, (c.sequence += 1))

function client_transaction(c)
    t = Transaction(c)
    startwrite(t)
    return t
end


getparser(t::Transaction) = t.c.parser

getrawstream(t::Transaction) = t.c.io


inactiveseconds(t::Transaction) = inactiveseconds(t.c)

function inactiveseconds(c::Connection)::Float64
    if !c.readbusy && !c.writebusy
        return Float64(0)
    end
    return time() - c.timestamp
end


Base.unsafe_write(t::Transaction, p::Ptr{UInt8}, n::UInt) =
    unsafe_write(t.c.io, p, n)

Base.isopen(c::Connection) = isopen(c.io)

Base.isopen(t::Transaction) = isopen(t.c) &&
                              t.c.readcount <= t.sequence &&
                              t.c.writecount <= t.sequence

function Base.eof(t::Transaction)
    @require isreadable(t) || !isopen(t)
    if bytesavailable(t) > 0
        return false
    end                 ;@debug 4 "eof(::Transaction) -> eof($typeof(c.io)): $t"
    return eof(t.c.io)
end

bytesavailable(t::Transaction) = bytesavailable(t.c)
bytesavailable(c::Connection) =
    !isempty(c.excess) ? length(c.excess) : bytesavailable(c.io)


Base.isreadable(t::Transaction) = t.c.readbusy && t.c.readcount == t.sequence

Base.iswritable(t::Transaction) = t.c.writebusy && t.c.writecount == t.sequence


function Base.readavailable(t::Transaction)::ByteView
    @require isreadable(t)
    if !isempty(t.c.excess)
        bytes = t.c.excess
        @debug 4 "↩️  read $(length(bytes))-bytes from excess buffer."
        t.c.excess = nobytes
    else
        bytes = byteview(readavailable(t.c.io))
        @debug 4 "⬅️  read $(length(bytes))-bytes from $(typeof(t.c.io))"
    end
    t.c.timestamp = time()
    return bytes
end



@static if !isdefined(Base, :copyto!)
    const copyto! = copy!
end

function Base.readbytes!(t::Transaction, a::Vector{UInt8}, nb::Int)

    if !isempty(t.c.excess)
        l = length(t.c.excess)
        copyto!(a, 1, t.c.excess, 1, min(l, nb))
        if l > nb
            t.c.excess = view(t.c.excess, nb+1:l)
            return nb
        else
            t.c.excess = nobytes
            return l + readbytes!(t.c.io, view(a, l+1:nb))
        end
    end

    return readbytes!(t.c.io, a, nb)
end


"""
    unread!(::Transaction, bytes)

Push bytes back into a connection's `excess` buffer
(to be returned by the next read).
"""

function IOExtras.unread!(t::Transaction, bytes::ByteView)
    @require isreadable(t)
    t.c.excess = bytes
    return
end


"""
    startwrite(::Transaction)

Wait for prior pending writes to complete.
"""

function IOExtras.startwrite(t::Transaction)
    @require !iswritable(t)                     ;t.c.writecount != t.sequence &&
                                                   @debug 1 "⏳  Wait write: $t"
    while t.c.writecount != t.sequence
        wait(t.c.writedone)
    end                                           ;@debug 2 "👁  Start write:$t"
    t.c.writebusy = true
    @ensure iswritable(t)
    return
end


"""
    closewrite(::Transaction)

Signal that an entire Request Message has been written to the `Transaction`.
"""

function IOExtras.closewrite(t::Transaction)
    @require iswritable(t)

    t.c.writebusy = false
    t.c.writecount += 1                           ;@debug 2 "🗣  Write done: $t"
    notify(t.c.writedone)
    notify(poolcondition)

    @ensure !iswritable(t)
    return
end


"""
    startread(::Transaction)

Wait for prior pending reads to complete.
"""

function IOExtras.startread(t::Transaction)
    @require !isreadable(t)                      ;t.c.readcount != t.sequence &&
                                                   @debug 1 "⏳  Wait read:  $t"
    t.c.timestamp = time()
    while t.c.readcount != t.sequence
        wait(t.c.readdone)
    end                                           ;@debug 2 "👁  Start read: $t"
    t.c.readbusy = true
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

    t.c.readbusy = false
    t.c.readcount += 1
    notify(t.c.readdone)                          ;@debug 2 "✉️  Read done:  $t"
    notify(poolcondition)

    @ensure !isreadable(t)
    return
end

function Base.close(t::Transaction)
    close(t.c)
    if iswritable(t)
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
    notify(poolcondition)
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
    c.excess = nobytes
    @ensure bytesavailable(c) == 0
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

const pool = Vector{Connection}()
const poollock = ReentrantLock()
const poolcondition = Condition()

"""
    closeall()

Close all connections in `pool`.
"""

function closeall()

    lock(poollock)
    for c in pool
        close(c)
    end
    empty!(pool)
    unlock(poollock)
    notify(poolcondition)
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
                      reuse_limit::Int)

    filter(c->(!c.writebusy &&
               typeof(c.io) == T &&
               c.host == host &&
               c.port == port &&
               c.pipeline_limit == pipeline_limit &&
               c.writecount < reuse_limit &&
               c.writecount - c.readcount < pipeline_limit + 1 &&
               isopen(c.io)), pool)
end


"""
    findoverused(type, host, port, reuse_limit) -> Vector{Connection}

Find `Connections` in the `pool` that are over the reuse limit
and have no more active readers.
"""

function findoverused(T::Type,
                      host::AbstractString,
                      port::AbstractString,
                      reuse_limit::Int)

    filter(c->(typeof(c.io) == T &&
               c.host == host &&
               c.port == port &&
               c.readcount >= reuse_limit &&
               !c.readbusy &&
               isopen(c.io)), pool)
end


"""
    findall(type, host, port) -> Vector{Connection}

Find all `Connections` in the `pool` for `host` and `port`.
"""

function findall(T::Type,
                 host::AbstractString,
                 port::AbstractString,
                 pipeline_limit::Int)

    filter(c->(typeof(c.io) == T &&
               c.host == host &&
               c.port == port &&
               c.pipeline_limit == pipeline_limit &&
               isopen(c.io)), pool)
end


"""
    purge()

Remove closed connections from `pool`.
"""
function purge()
    isdeletable(c) = !isopen(c.io) && (@debug 1 "🗑  Deleted:        $c"; true)
    deleteat!(pool, map(isdeletable, pool))
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
                       reuse_limit::Int=nolimit,
                       kw...)::Transaction{T} where T <: IO

    while true

        lock(poollock)
        try

            # Close connections that have reached the reuse limit...
            if reuse_limit != nolimit
                for c in findoverused(T, host, port, reuse_limit)
                    close(c)
                end
            end

            # Remove closed connections from `pool`...
            purge()

            # Try to find a connection with no active readers or writers...
            writable = findwritable(T, host, port, pipeline_limit, reuse_limit)
            idle = filter(c->!c.readbusy, writable)
            if !isempty(idle)
                c = rand(idle)                 ;@debug 2 "♻️  Idle:           $c"
                return client_transaction(c)
            end

            # If there are not too many connections to this host:port,
            # create a new connection...
            busy = findall(T, host, port, pipeline_limit)
            if length(busy) < connection_limit
                io = getconnection(T, host, port; kw...)
                c = Connection(host, port, pipeline_limit, io)
                push!(pool, c)                ;@debug 1 "🔗  New:            $c"
                return client_transaction(c)
            end

            # Share a connection that has active readers...
            if !isempty(writable)
                c = rand(writable)             ;@debug 2 "⇆  Shared:         $c"
                return client_transaction(c)
            end

        finally
            unlock(poollock)
        end

        # Wait for `closewrite` or `close` to signal that a connection is ready.
        wait(poolcondition)
    end
end


function getconnection(::Type{TCPSocket},
                       host::AbstractString,
                       port::AbstractString;
                       kw...)::TCPSocket

    p::UInt = isempty(port) ? UInt(80) : parse(UInt, port)
    @debug 2 "TCP connect: $host:$p..."
    connect(getaddrinfo(host), p)
end


const nosslconfig = SSLConfig()
default_sslconfig = nothing
noverify_sslconfig = nothing

function global_sslconfig(require_ssl_verification::Bool)::SSLConfig
    global default_sslconfig
    global noverify_sslconfig
    if default_sslconfig == nothing
        default_sslconfig = SSLConfig(true)
        noverify_sslconfig = SSLConfig(false)
    end
    return require_ssl_verification ? default_sslconfig : noverify_sslconfig
end

function getconnection(::Type{SSLContext},
                       host::AbstractString,
                       port::AbstractString;
                       require_ssl_verification::Bool=true,
                       sslconfig::SSLConfig=nosslconfig,
                       kw...)::SSLContext

    if sslconfig === nosslconfig
        sslconfig = global_sslconfig(require_ssl_verification)
    end

    port = isempty(port) ? "443" : port
    @debug 2 "SSL connect: $host:$port..."
    io = SSLContext()
    setup!(io, sslconfig)
    associate!(io, getconnection(TCPSocket, host, port))
    hostname!(io, host)
    handshake!(io)
    return io
end


function Base.show(io::IO, c::Connection)
    nwaiting = bytesavailable(tcpsocket(c.io))
    print(
        io,
        tcpstatus(c), " ",
        lpad(c.writecount,3),"↑", c.writebusy ? "🔒  " : "   ",
        lpad(c.readcount,3), "↓", c.readbusy ? "🔒   " : "    ",
        c.host, ":",
        c.port != "" ? c.port : Int(c.peerport), ":", Int(c.localport),
        " ≣", c.pipeline_limit,
        length(c.excess) > 0 ? " $(length(c.excess))-byte excess" : "",
        inactiveseconds(c) > 5 ?
            " inactive $(round(inactiveseconds(c),1))s" : "",
        nwaiting > 0 ? " $nwaiting bytes waiting" : "",
        DEBUG_LEVEL > 1 ? " $(Base._fd(tcpsocket(c.io)))" : "")
end

Base.show(io::IO, t::Transaction) = print(io, "T$(rpad(t.sequence,2)) ", t.c)


function tcpstatus(c::Connection)
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
    lock(poollock)
    println(io, "ConnectionPool[")
    for c in pool
        println(io, "   $c")
    end
    println(io, "]\n")
    unlock(poollock)
end

function showpoolhtml(io::IO)
    lock(poollock)
    println(io, "<table>")
    for c in pool
        print(io, "<tr>")
        for x in split("$c")
            print(io, "<td>$x</td>")
        end
        println(io, "<tr>")
    end
    println(io, "</table>")
    unlock(poollock)
end

end # module ConnectionPool
