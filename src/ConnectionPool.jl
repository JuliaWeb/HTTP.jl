module ConnectionPool

export getconnection, getparser

using ..IOExtras

import ..@debug, ..DEBUG_LEVEL, ..taskid
import MbedTLS.SSLContext
import ..Connect: getconnection, getparser
import ..Parsers.Parser


const duplicate_connection_limit = 8
const default_pipeline_limit = 16
const nolimit = typemax(Int)

const force_lock_assert = true

const nobytes = view(UInt8[], 1:0)
const ByteView = typeof(nobytes)
byteview(bytes::ByteView) = bytes
byteview(bytes)::ByteView = view(bytes, 1:length(bytes))


"""
    Connection{T <: IO}

A `TCPSocket` or `SSLContext` connection to a HTTP `host` and `port`.

- `host::String`
- `port::String`
- `io::T`, the `TCPSocket` or `SSLContext.
- `excess::ByteView`, left over bytes read from the connection after
   the end of a response message. These bytes are probably the start of the
   next response message.
- `writecount`, number of Request Messages that have been written.
- `readcount`, number of Response Messages that have been read.
- `writelock`, busy writing a Request to `io`.
- `readlock`, busy reading a Response from `io`.
- `parser::Parser`, reuse a `Parser` when this `Connection` is reused.
"""

mutable struct Connection{T <: IO} <: IO
    host::String
    port::String
    pipeline_limit::Int
    peerport::UInt16
    localport::UInt16
    io::T
    excess::ByteView
    writecount::Int
    readcount::Int
    writelock::ReentrantLock
    readlock::ReentrantLock
    parser::Parser
end


Connection{T}(host::AbstractString, port::AbstractString,
              pipeline_limit::Int, io::T) where T <: IO =
    Connection{T}(host, port, pipeline_limit,
                  peerport(io), localport(io), io, view(UInt8[], 1:0), 0, 0,
                  ReentrantLock(), ReentrantLock(), Parser())


getparser(c::Connection) = c.parser


Base.unsafe_write(c::Connection, p::Ptr{UInt8}, n::UInt) =
    unsafe_write(c.io, p, n)

Base.isopen(c::Connection) = isopen(c.io)

function Base.eof(c::Connection)
    if nb_available(c) > 0
        return false
    end
                     @debug 3 "eof(::Connection) calling eof($typeof(c.io)): $c"
    return eof(c.io)
end

Base.nb_available(c::Connection) = !isempty(c.excess) ? length(c.excess) :
                                                        nb_available(c.io)
Base.isreadable(c::Connection) = havelock(c.readlock)
Base.iswritable(c::Connection) = havelock(c.writelock)


macro lockassert(cond)
    DEBUG_LEVEL > 0 || force_lock_assert ? esc(:(@assert $cond)) : :()
end

function havelock(l)
    @lockassert l.reentrancy_cnt <= 1
    islocked(l) && l.locked_by == current_task()
end


function Base.readavailable(c::Connection)::ByteView
    @lockassert isreadable(c)
    if !isempty(c.excess)
        bytes = c.excess
        @debug 3 "↩️  read $(length(bytes))-bytes from excess buffer."
        c.excess = nobytes
    else
        bytes = byteview(readavailable(c.io))
        @debug 3 "⬅️  read $(length(bytes))-bytes from $(typeof(c.io))"
    end
    return bytes
end


"""
    unread!(::Connection, bytes)

Push bytes back into a connection's `excess` buffer
(to be returned by the next read).
"""

function IOExtras.unread!(c::Connection, bytes::ByteView)
    @lockassert isreadable(c)
    c.excess = bytes
end


"""
    closewrite(::Connection)

Signal that an entire Request Message has been written to the `Connection`.

Increment `writecount` and wait for pending reads to complete.
"""

function IOExtras.closewrite(c::Connection)
    @lockassert iswritable(c)

    seq = c.writecount
    c.writecount += 1                             ;@debug 2 "🗣  Write done: $c"
    unlock(c.writelock)
    notify(poolcondition)

    if !isreadable(c)
        startread(c, seq)
    end
    @lockassert isreadable(c)
end


"""
    startread(::Connection)

Wait for prior pending reads to complete, then lock the readlock.
"""

function startread(c::Connection)
    @lockassert iswritable(c)

    startread(c, c.writecount)
end

function startread(c::Connection, seq::Int)
    @lockassert !isreadable(c)

    lock(c.readlock)
    while c.readcount != seq
        if !isopen(c) && nb_available(c) == 0
            # If there is nothing left to read,
            # then unlocking sequence is irrelevant.
            break
        end
        unlock(c.readlock)
        yield()                        ;@debug 1 "⏳  seq=$(lpad(seq,3)):    $c"
        lock(c.readlock)
    end
    @lockassert isreadable(c)
    return
end


"""
    closeread(::Connection)

Signal that an entire Response Message has been read from the `Connection`.

Increment `readcount` and wake up tasks waiting in `closewrite`.
"""

function IOExtras.closeread(c::Connection)
    @lockassert isreadable(c)
    c.readcount += 1
    unlock(c.readlock)                            ;@debug 2 "✉️  Read done:  $c"
    notify(poolcondition)
    return
end


function Base.close(c::Connection)
    close(c.io)                                   ;@debug 2 "🚫      Closed: $c"
    if isreadable(c)
        purge(c)
        closeread(c)
    end
    return
end


"""
    purge(::Connection)

Remove unread data from a `Connection`.
"""

function purge(c::Connection)
    @assert !isopen(c)
    while !eof(c.io)
        readavailable(c.io)
    end
    c.excess = nobytes
    @assert nb_available(c) == 0
end


"""
    pool

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

    filter(c->(typeof(c.io) == T &&
               c.host == host &&
               c.port == port &&
               c.pipeline_limit == pipeline_limit &&
               c.writecount < reuse_limit &&
               c.writecount - c.readcount < pipeline_limit &&
               !islocked(c.writelock) &&
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
               !islocked(c.readlock) &&
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
    while (i = findfirst(x->!isopen(x.io) &&
           x.readcount == x.writecount, pool)) > 0
        c = pool[i]
        purge(c)
        deleteat!(pool, i)                        ;@debug 1 "🗑  Deleted:    $c"
    end
end


"""
    getconnection(type, host, port) -> Connection

Find a reusable `Connection` in the `pool`,
or create a new `Connection` if required.
"""

function getconnection(::Type{Connection{T}},
                       host::AbstractString,
                       port::AbstractString;
                       pipeline_limit::Int = default_pipeline_limit,
                       reuse_limit::Int = nolimit,
                       kw...)::Connection{T} where T <: IO

    while true

        lock(poollock)
        @lockassert poollock.reentrancy_cnt == 1
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
            idle = filter(c->!islocked(c.readlock), writable)
            if !isempty(idle)
                c = rand(idle)                     ;@debug 1 "♻️  Idle:       $c"
                lock(c.writelock)
                return c
            end

            # If there are not too many duplicates for this host,
            # create a new connection...
            busy = findall(T, host, port, pipeline_limit)
            if length(busy) < duplicate_connection_limit
                io = getconnection(T, host, port; kw...)
                c = Connection{T}(host, port, pipeline_limit, io)
                lock(c.writelock)
                push!(pool, c)                    ;@debug 1 "🔗  New:        $c"
                return c
            end

            # Share a connection that has active readers...
            if !isempty(writable)
                c = rand(writable)                 ;@debug 1 "⇆  Shared:     $c"
                lock(c.writelock)
                return c
            end

        finally
            unlock(poollock)
        end

        # Wait for `closewrite` or `close` to signal that a connection is ready.
        wait(poolcondition)
    end
end


function Base.show(io::IO, c::Connection)
    nwaiting = nb_available(tcpsocket(c.io))
    print(
        io,
        tcpstatus(c), " ",
        lpad(c.writecount,3),"↑", islocked(c.writelock) ? "🔒  " : "   ",
        lpad(c.readcount,3), "↓", islocked(c.readlock) ? "🔒   " : "    ",
        c.host, ":",
        c.port != "" ? c.port : Int(c.peerport), ":", Int(c.localport),
        ", ≣", c.pipeline_limit,
        length(c.excess) > 0 ? ", $(length(c.excess))-byte excess" : "",
        nwaiting > 0 ? ", $nwaiting bytes waiting" : "",
        DEBUG_LEVEL > 0 ? ", $(Base._fd(tcpsocket(c.io)))" : "",
        DEBUG_LEVEL > 0 &&
        islocked(c.writelock) ?  ", write task: $(taskid(c.writelock))" : "",
        DEBUG_LEVEL > 0 &&
        islocked(c.readlock) ?  ", read task: $(taskid(c.readlock))" : "")
end


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
    println("]\n")
    unlock(poollock)
end

end # module ConnectionPool
