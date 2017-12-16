module ConnectionPool

export getconnection, getparser

using ..IOExtras

import ..@debug, ..DEBUG_LEVEL
import MbedTLS.SSLContext
import ..Connect: getconnection, getparser
import ..Parsers.Parser


const ByteView = typeof(view(UInt8[], 1:0))


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

Base.unsafe_write(c::Connection, p::Ptr{UInt8}, n::UInt) =
    unsafe_write(c.io, p, n)

Base.eof(c::Connection) = isempty(c.excess) && eof(c.io)

function Base.readavailable(c::Connection)
    if !isempty(c.excess)
        bytes = c.excess
        @debug 3 "read $(length(bytes))-bytes from excess buffer."
        c.excess = view(UInt8[], 1:0)
    else
        bytes = readavailable(c.io)
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
    @assert isempty(c.excess)
    c.excess = bytes
end


"""
    closewrite(::Connection)

Signal that an entire Request Message has been written to the `Connection`.

Increment `writecount` and wait for pending reads to complete.
"""

function IOExtras.closewrite(c::Connection)
    c.writecount += 1
    if islocked(c.readlock)
        @debug 3 "Waiting to read: $c"
    end
    if isopen(c.io)
        lock(c.readlock)
        if !isopen(c.io)
            unlock(c.readlock)
        end
        unlock(c.writelock)
    end
    @assert isopen(c.io) == islocked(c.readlock)
end


"""
    closeread(::Connection)

Signal that an entire Response Message has been read from the `Connection`.

Increment `readcount` and wake up waiting `closewrite`.
"""

function IOExtras.closeread(c::Connection)
    c.readcount += 1
    if isopen(c.io)
        unlock(c.readlock)
    end
end


function Base.close(c::Connection)
    close(c.io)
    if islocked(c.readlock)
        unlock(c.readlock)
    end
    if islocked(c.writelock)
        unlock(c.writelock)
    end
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


"""
    getconnection(type, host, port) -> Connection

Find a reusable `Connection` in the `pool`,
or create a new `Connection` if required.
"""

function getconnection(::Type{Connection{T}},
                       host::AbstractString,
                       port::AbstractString;
                       kw...)::Connection{T} where T <: IO

    lock(poollock)
    try

        pattern = x->(!islocked(x.writelock) &&
                      typeof(x.io) == T &&
                      x.host == host &&
                      x.port == port)

        while (i = findlast(pattern, pool)) > 0
            c = pool[i]
            if !isopen(c.io)
                deleteat!(pool, i)                ;@debug 1 "Deleted: $c"
                continue
            end;                                  ;@debug 2 "Reused: $c"
            lock(c.writelock)
            return c
        end

        io = getconnection(T, host, port; kw...)
        c = Connection{T}(host, port, io)         ;@debug 1 "New: $c"
        push!(pool, c)
        lock(c.writelock)
        return c

    finally
        unlock(poollock)
    end
end


getparser(c::Connection) = c.parser


function Base.show(io::IO, c::Connection)
    print(io, c.host, ":",
              c.port != "" ? c.port : Int(peerport(c)), ":",
              Int(localport(c)), ", ",
              typeof(c.io), ", ", tcpstatus(c), ", ",
              length(c.excess), "-byte excess, reads/writes: ",
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


end # module ConnectionPool
