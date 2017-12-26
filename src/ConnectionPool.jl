module ConnectionPool

export getconnection, getparser

using ..IOExtras

import ..@debug, ..DEBUG_LEVEL
import MbedTLS.SSLContext
import ..Connect: getconnection, getparser
import ..Parsers.Parser

const max_duplicates = 8
const nolimit = typemax(Int)

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
    io::T
    excess::ByteView
    writecount::Int
    readcount::Int
    writelock::ReentrantLock
    readlock::ReentrantLock
    parser::Parser
end


Connection{T}(host::AbstractString, port::AbstractString, io::T) where T <: IO =
    Connection{T}(host, port, io, view(UInt8[], 1:0), 0, 0,
                  ReentrantLock(), ReentrantLock(), Parser())

const noconnection = Connection{TCPSocket}("","",TCPSocket())

getparser(c::Connection) = c.parser


Base.unsafe_write(c::Connection, p::Ptr{UInt8}, n::UInt) =
    unsafe_write(c.io, p, n)

Base.eof(c::Connection) = isempty(c.excess) && eof(c.io)


function Base.readavailable(c::Connection)::ByteView
    if !isempty(c.excess)
        bytes = c.excess
        @debug 3 "read $(length(bytes))-bytes from excess buffer."
        c.excess = nobytes
    else
        bytes = byteview(readavailable(c.io))
        @debug 3 "read $(length(bytes))-bytes from $(typeof(c.io))"
    end
    return bytes
end


"""
    unread!(::Connection, bytes)

Push bytes back into a connection's `excess` buffer
(to be returned by the next read).
"""

IOExtras.unread!(c::Connection, bytes::ByteView) = c.excess = bytes


"""
    closewrite(::Connection)

Signal that an entire Request Message has been written to the `Connection`.

Increment `writecount` and wait for pending reads to complete.
"""

function IOExtras.closewrite(c::Connection)
    seq = c.writecount
    c.writecount += 1;                            @debug 2 "write done: $c"

    # The write lock may already have been unlocked by `close` or `purge`.
    if islocked(c.writelock)
        unlock(c.writelock)
        notify(poolcondition)
    end
    lock(c.readlock)
    # Wait for prior pending reads to complete...
    while c.readcount != seq
        unlock(c.readlock)
        yield()
        lock(c.readlock)
        # Error if there is nothing to read.
        if !isopen(c.io) && nb_available(c.io) == 0
            unlock(c.readlock)
            throw(EOFError())
        end
    end
    return
end


"""
    closeread(::Connection)

Signal that an entire Response Message has been read from the `Connection`.

Increment `readcount` and wake up tasks waiting in `closewrite`.
"""

function IOExtras.closeread(c::Connection)
    c.readcount += 1;                             @debug 2 "read done: $c"
    if islocked(c.readlock)
        unlock(c.readlock)
    end
    notify(poolcondition)
    return
end


function Base.close(c::Connection)
    close(c.io)
    if islocked(c.readlock)
        unlock(c.readlock)
    end
    if islocked(c.writelock)
        unlock(c.writelock)
    end
    notify(poolcondition)
    return
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
    findwriteable(type, host, port) -> Vector{Connection}

Find `Connections` in the `pool` that are ready for writing.
"""

function findwriteable(T::Type,
                       host::AbstractString,
                       port::AbstractString,
                       reuse_limit::Int=nolimit)

    filter(c->(typeof(c.io) == T &&
               c.host == host &&
               c.port == port &&
               c.writecount < reuse_limit &&
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
                 port::AbstractString)

    filter(c->(typeof(c.io) == T &&
               c.host == host &&
               c.port == port &&
               isopen(c.io)), pool)
end


"""
    purge()

Remove closed connections from `pool`.
"""
function purge()
    while (i = findfirst(x->!isopen(x.io), pool)) > 0
        c = pool[i]
        if islocked(c.readlock)
            unlock(c.readlock)
        end
        if islocked(c.writelock)
            unlock(c.writelock)
        end
        deleteat!(pool, i)                               ;@debug 1 "Deleted: $c"
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
                       reuse_limit::Int = nolimit,
                       kw...)::Connection{T} where T <: IO

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
            writeable = findwriteable(T, host, port, reuse_limit)
            idle = filter(c->!islocked(c.readlock), writeable)
            if !isempty(idle)
                c = rand(idle)                            ;@debug 2 "Idle: $c"
                lock(c.writelock)
                return c
            end

            # If there are not too many duplicates for this host,
            # create a new connection...
            busy = findall(T, host, port)
            if length(busy) < max_duplicates
                io = getconnection(T, host, port; kw...)
                c = Connection{T}(host, port, io)         ;@debug 1 "New: $c"
                lock(c.writelock)
                push!(pool, c)
                return c
            end

            # Share a connection that has active readers...
            if !isempty(writeable)
                c = rand(writeable)                       ;@debug 2 "Shared: $c"
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
    print(io, c.host, ":",
              c.port != "" ? c.port : Int(peerport(c)), ":",
              Int(localport(c)), ", ",
              typeof(c.io), ", ", tcpstatus(c), ", ",
              length(c.excess), "-byte excess, writes/reads: ",
              c.writecount, "/", c.readcount)
end

tcpsocket(c::Connection{SSLContext})::TCPSocket = c.io.bio
tcpsocket(c::Connection{TCPSocket})::TCPSocket = c.io

localport(c::Connection) = !isopen(c.io) ? 0 :
                           VERSION > v"0.7.0-DEV" ?
                           getsockname(tcpsocket(c))[2] :
                           Base._sockname(tcpsocket(c), true)[2]

peerport(c::Connection) = !isopen(c.io) ? 0 :
                          VERSION > v"0.7.0-DEV" ?
                          getpeername(tcpsocket(c))[2] :
                          Base._sockname(tcpsocket(c), false)[2]

tcpstatus(c::Connection) = Base.uv_status_string(tcpsocket(c))

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
