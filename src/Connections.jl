module Connections

export getconnection, readresponse!, unread!

using MbedTLS: SSLContext


import ..@lock
import ..@debug

include("Connect.jl")
import .Connect.unread!

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
    readlock::ReentrantLock
end

Connection{T}() where T <: IO =
    Connection{T}("", 0, T(), view(UInt8[], 1:0), ReentrantLock())

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
        @debug "read $(length(bytes))-bytes from excess buffer."
        c.excess = view(UInt8[], 1:0)
    else
        bytes = readavailable(c.io)
        @debug "read $(length(bytes))-bytes from $(typeof(c.io))"
    end
    return bytes
end


"""
    readresponse!(::Connection, response)

Read from a `Connection` and store result in `response`.
Lock the `readlock` and push the `Connection` back into the `pool` for reuse.
"""

function readresponse!(c::Connection, response)
    @lock c.readlock begin
        pushconnection!(c)
        return read!(c, response)
    end
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
    pushconnection!(c::Connection)

Place a `Connection` in the `pool` for reuse.
"""

pushconnection!(c::Connection) = @lock poollock push!(pool, c)


"""
    popconnection!(type, host, port [, default=noconnection])

Find a `Connection` and remove it from the `pool`.
"""

function popconnection!(t::Type, host::String, port::UInt, default=noconnection)
    @lock poollock begin
        pattern = c->(typeof(c.io) == t && c.host == host && c.port == port)
        if (i = findlast(pattern, pool)) > 0
            x = pool[i]
            deleteat!(pool, i)
            return x
        end
    end
    return default
end


"""
    getconnection(type, host, port)

Find a reusable `Connection` and remove it from the `pool`,
or create a new `Connection` if required.
"""

function getconnection(::Type{T}, host::String, port::UInt) where T <: IO

    while (c = popconnection!(T, host, port)) != noconnection
        if isopen(c.io)
            @debug "Reused: $c"
            return c
        end
        @debug "Discarded: $c"
    end

    c = Connection{T}(host, port)
    @debug "New: $c"
    return c
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
