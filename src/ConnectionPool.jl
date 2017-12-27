module ConnectionPool

export getconnection, getparser

using ..IOExtras

import ..@debug, ..DEBUG_LEVEL
import MbedTLS.SSLContext
import ..Connect: getconnection, getparser
import ..Parsers.Parser


const max_duplicates = 8
const nolimit = typemax(Int)


macro lockassert(cond)
    DEBUG_LEVEL > 1 ? esc(:(@assert $cond)) : :() #FIXME
end

struct NonReentrantLock
    l::ReentrantLock
end

NonReentrantLock() = NonReentrantLock(ReentrantLock())

Base.islocked(l::NonReentrantLock) = islocked(l.l)
havelock(l) = islocked(l) && l.l.locked_by == current_task()

function Base.lock(l::NonReentrantLock)
    @lockassert !havelock(l)
    lock(l.l)
    @lockassert l.l.reentrancy_cnt == 1
end

function Base.unlock(l::NonReentrantLock)
    @lockassert havelock(l)
    @lockassert l.l.reentrancy_cnt == 1
    unlock(l.l)
end


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
    writelock::NonReentrantLock
    readlock::NonReentrantLock
    parser::Parser
end


Connection{T}(host::AbstractString, port::AbstractString, io::T) where T <: IO =
    Connection{T}(host, port, io, view(UInt8[], 1:0), 0, 0,
                  NonReentrantLock(), NonReentrantLock(), Parser())

const noconnection = Connection{TCPSocket}("","",TCPSocket())


getparser(c::Connection) = c.parser


Base.unsafe_write(c::Connection, p::Ptr{UInt8}, n::UInt) =
    unsafe_write(c.io, p, n)

Base.isopen(c::Connection) = isopen(c.io)
Base.eof(c::Connection) = isempty(c.excess) && eof(c.io)
Base.nb_available(c::Connection) = !isempty(c.excess) ? length(c.excess) :
                                                        nb_available(c.io)
Base.isreadable(c::Connection) = havelock(c.readlock)
Base.iswritable(c::Connection) = havelock(c.writelock)


function Base.readavailable(c::Connection)::ByteView
    @lockassert isreadable(c)
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
    c.writecount += 1                                 ;@debug 2 "Write done: $c"
    unlock(c.writelock)
    notify(poolcondition)

    lock(c.readlock)
    # Wait for prior pending reads to complete...
    while c.readcount != seq
        if !isopen(c) && nb_available(c) == 0
            break
        end
        unlock(c.readlock)               ;@debug 1 "Waiting to read seq=$seq: $c"
        yield()
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
    c.readcount += 1                                  ;@debug 2 "Read done: $c"
    unlock(c.readlock)
    notify(poolcondition)
    return
end


function Base.close(c::Connection)
    close(c.io)                                           ;@debug 2 "Closed: $c"
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
    while (i = findfirst(x->!isopen(x.io) &&
                         x.readcount == x.writecount, pool)) > 0
        c = pool[i]
        purge(c)
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
            writable = findwritable(T, host, port, reuse_limit)
            idle = filter(c->!islocked(c.readlock), writable)
            if !isempty(idle)
                c = rand(idle)                              ;@debug 2 "Idle: $c"
                lock(c.writelock)
                return c
            end

            # If there are not too many duplicates for this host,
            # create a new connection...
            busy = findall(T, host, port)
            if length(busy) < max_duplicates
                io = getconnection(T, host, port; kw...)
                c = Connection{T}(host, port, io)            ;@debug 1 "New: $c"
                lock(c.writelock)
                push!(pool, c)
                return c
            end

            # Share a connection that has active readers...
            if !isempty(writable)
                c = rand(writable)                        ;@debug 2 "Shared: $c"
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
              c.writecount, "/", c.readcount,
              islocked(c.readlock) ? ", readlock" : "",
              islocked(c.writelock) ? ", writelock" : "")
end

tcpsocket(c::Connection{SSLContext})::TCPSocket = c.io.bio
tcpsocket(c::Connection{TCPSocket})::TCPSocket = c.io

localport(c::Connection) = try !isopen(tcpsocket(c)) ? 0 :
                               VERSION > v"0.7.0-DEV" ?
                               getsockname(tcpsocket(c))[2] :
                               Base._sockname(tcpsocket(c), true)[2]
                           catch
                               0
                           end

peerport(c::Connection) = try !isopen(tcpsocket(c)) ? 0 :
                              VERSION > v"0.7.0-DEV" ?
                              getpeername(tcpsocket(c))[2] :
                              Base._sockname(tcpsocket(c), false)[2]
                           catch
                               0
                           end

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
