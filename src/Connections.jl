module Connections

export getconnection, readresponse!, unread!, closeread, closewrite

import ..@lock, ..@debug, ..SSLContext

import ..Connect: Connect, unread!, closeread, closewrite


const ByteView = typeof(view(UInt8[], 1:0))


"""
    Connection

A `TCPSocket` or `SSLContext` connection to a HTTP `host` and `port`.

The `excess` field contains left over bytes read from the connection after
the end of a response message. These bytes are probably the start of the
next response message.

The `readlock` is held by the `read!` function until the end of the response
message is parsed. A second `request` task that has sent a message on this
`Connection` must wait to obtain the lock before reading its response.
"""

mutable struct Connection{T <: IO} <: IO
    host::String
    port::UInt
    io::T
    excess::ByteView
    writebusy::Bool
    readlock::ReentrantLock
end

Connection{T}() where T <: IO =
    Connection{T}("", 0, T(), view(UInt8[], 1:0), false, ReentrantLock())

function Connection{T}(host::String, port::UInt) where T <: IO
    c = Connection{T}()
    c.host = host
    c.port = port
    c.io = Connect.getconnection(T, host, port)
    return c
end

const noconnection = Connection{TCPSocket}()

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

Push bytes back into a connection (to be returned by the next read).
"""

function unread!(c::Connection, bytes::ByteView)
    @assert isempty(c.excess)
    c.excess = bytes
end


"""
    closewrite(::Connection)

Signal end of writing (and obtain lock for reading).
"""

function closewrite(c::Connection)
    c.writebusy = false
    lock(c.readlock)
    @debug 2 "Pooled: $c"
end


"""
    closeread(::Connection)

Signal end of read operations.
"""

closeread(c::Connection) = unlock(c.readlock)

Base.close(c::Connection) = close(c.io)


"""
    pool

The `pool` is a collection of open `Connection`s that are available
for sending Request Messages. The `request` function calls
`getconnection` to retrieve a connection from the `pool`.
When the `request` function has sent a Request Message it returns the
`Connection` to the `pool`. When a `Connection` is first returned
to the pool, its `readlock` set to indicate that the requester has
not finished reading the Response Message. At this point a new
requester can use the `Connection` to send another Request Message,
but must wait to the `readlock` before reading the Response Message.
"""

const pool = Vector{Connection}()
const poollock = ReentrantLock()


"""
    getconnection(type, host, port) -> Connection

Find a reusable `Connection` and remove it from the `pool`,
or create a new `Connection` if required.
"""

function getconnection(::Type{T}, host::String, port::UInt) where T <: IO

    @lock poollock begin

        pattern = x->(!x.writebusy &&
                      typeof(x.io) == T &&
                      x.host == host &&
                      x.port == port)

        while (i = findlast(pattern, pool)) > 0
            c = pool[i]
            if !isopen(c.io)
                deleteat!(pool, i)      ;@debug 1 "Deleted: $c"
                continue
            end
            c.writebusy = true;         ;@debug 2 "Reused: $c"
            return c
        end

        c = Connection{T}(host, port)   ;@debug 1 "New: $c"
        c.writebusy = true
        push!(pool, c)
        return c
    end
end


function Base.show(io::IO, c::Connection)
    print(io, c.host, ":", Int(c.port), ":", Int(localport(c)), ", ",
              typeof(c.io), ", ", tcpstatus(c), ", ",
              length(c.excess), "-byte excess",
              islocked(c.readlock) ? ", readlock" : "")
end

tcpsocket(c::Connection{SSLContext})::TCPSocket = c.io.bio
tcpsocket(c::Connection{TCPSocket})::TCPSocket = c.io

localport(c::Connection) = VERSION > v"0.7.0-DEV" ?
                           getsockname(tcpsocket(c))[2] :
                           Base._sockname(tcpsocket(c), true)[2]

tcpstatus(c::Connection) = Base.uv_status_string(tcpsocket(c))


end # module Connections
