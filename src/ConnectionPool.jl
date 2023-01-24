"""
This module provides the [`newconnection`](@ref) function with support for:
- Opening TCP and SSL connections.
- Reusing connections for multiple Request/Response Messages

This module defines a [`Connection`](@ref)
struct to manage the lifetime of a connection and its reuse.
Methods are provided for `eof`, `readavailable`,
`unsafe_write` and `close`.
This allows the `Connection` object to act as a proxy for the
`TCPSocket` or `SSLContext` that it wraps.

[`POOLS`](@ref) are used to manage connection pooling. Connections
are identified by their host, port, whether they require
ssl verification, and whether they are a client or server connection.
If a subsequent request matches these properties of a previous connection
and limits are respected (reuse limit, idle timeout), and it wasn't otherwise
remotely closed, a connection will be reused.
"""
module ConnectionPool

export Connection, newconnection, releaseconnection, getrawstream, inactiveseconds, shouldtimeout, set_default_connection_limit!

using Sockets, LoggingExtras, NetworkOptions
using MbedTLS: SSLConfig, SSLContext, setup!, associate!, hostname!, handshake!
using MbedTLS, OpenSSL
using ..IOExtras, ..Conditions, ..Exceptions

const default_connection_limit = Ref(8)
const nolimit = typemax(Int)

set_default_connection_limit!(n) = default_connection_limit[] = n

taskid(t=current_task()) = string(hash(t) & 0xffff, base=16, pad=4)

include("connectionpools.jl")
using .ConnectionPools

"""
    Connection

A `Sockets.TCPSocket`, `MbedTLS.SSLContext` or `OpenSSL.SSLStream` connection to a HTTP `host` and `port`.

Fields:
- `host::String`
- `port::String`, exactly as specified in the URI (i.e. may be empty).
- `idle_timeout`, No. of seconds to maintain connection after last request/response.
- `require_ssl_verification`, whether ssl verification is required for an ssl connection
- `peerip`, remote IP adress (used for debug/log messages).
- `peerport`, remote TCP port number (used for debug/log messages).
- `localport`, local TCP port number (used for debug messages).
- `io::T`, the `Sockets.TCPSocket`, `MbedTLS.SSLContext` or `OpenSSL.SSLStream`.
- `clientconnection::Bool`, whether the Connection was created from client code (as opposed to server code)
- `buffer::IOBuffer`, left over bytes read from the connection after
   the end of a response header (or chunksize). These bytes are usually
   part of the response body.
- `timestamp`, time data was last received.
- `readable`, whether the Connection object is readable
- `writable`, whether the Connection object is writable
"""
mutable struct Connection{IO_t <: IO} <: IO
    host::String
    port::String
    idle_timeout::Int
    require_ssl_verification::Bool
    peerip::IPAddr # for debugging/logging
    peerport::UInt16 # for debugging/logging
    localport::UInt16 # debug only
    io::IO_t
    clientconnection::Bool
    buffer::IOBuffer
    timestamp::Float64
    readable::Bool
    writable::Bool
    writebuffer::IOBuffer
    state::Any # populated & used by Servers code
end

"""
    connectionkey

Used for "hashing" a Connection object on just the key properties necessary for determining
connection re-useability. That is, when a new request calls `newconnection`, we take the
request parameters of what socket type, the host and port, and if ssl
verification is required, and if an existing Connection was already created with the exact
same parameters, we can re-use it (as long as it's not already being used, obviously).
"""
connectionkey(x::Connection) = (typeof(x.io), x.host, x.port, x.require_ssl_verification, x.clientconnection)

Connection(host::AbstractString, port::AbstractString,
           idle_timeout::Int,
           require_ssl_verification::Bool, io::T, client=true) where {T}=
    Connection{T}(host, port, idle_timeout,
                require_ssl_verification,
                safe_getpeername(io)..., localport(io),
                io, client, PipeBuffer(), time(), false, false, IOBuffer(), nothing)

Connection(io; require_ssl_verification::Bool=true) =
    Connection("", "", 0, require_ssl_verification, io, false)

getrawstream(c::Connection) = c.io

inactiveseconds(c::Connection)::Float64 = time() - c.timestamp

shouldtimeout(c::Connection, readtimeout) = !isreadable(c) || inactiveseconds(c) > readtimeout

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
    GC.@preserve bytes unsafe_read(c, pointer(bytes), nb)
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
        # try-catch underlying errors here
        # as the Connection object, we don't really care
        # if the underlying socket was closed/terminated
        # or just plain reached EOF, so we catch any
        # Base.IOErrors and just throw as EOFError
        # that way we get more consistent errors thrown
        # at the headers/body parsing level
        try
            unsafe_read(c.io, p, n)
            c.timestamp = time()
        catch e
            e isa Base.IOError && throw(EOFError())
            rethrow(e)
        end
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
    GC.@preserve buf unsafe_read(c.io, pointer(buf.data, buf.size + 1), n)
    buf.size += n
end

"""
Read until `find_delimiter(bytes)` returns non-zero.
Return view of bytes up to the delimiter.
"""
function Base.readuntil(c::Connection, f::F #=Vector{UInt8} -> Int=#,
                                        sizehint=4096)::ByteView where {F <: Function}
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
    @debugv 3 "👁  Start write:$c"
    return
end

"""
    closewrite(::Connection)

Signal that an entire Request Message has been written to the `Connection`.
"""
function IOExtras.closewrite(c::Connection)
    @require iswritable(c)
    c.writable = false
    @debugv 3 "🗣  Write done: $c"
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
    @debugv 3 "👁  Start read: $c"
    return
end

"""
Wait for `c` to receive data or reach EOF.
Close `c` on EOF.
TODO: or if response data arrives when no request was sent (isreadable == false).
"""
function monitor_idle_connection(c::Connection)
    try
        if eof(c.io)                                  ;@debugv 3 "💀  Closed:     $c"
            close(c.io)
        end
    catch ex
        @try Base.IOError close(c.io)
        ex isa Base.IOError || rethrow()
    end
    nothing
end

"""
    closeread(::Connection)

Signal that an entire Response Message has been read from the `Connection`.
"""
function IOExtras.closeread(c::Connection)
    @require isreadable(c)
    c.readable = false
    @debugv 3 "✉️  Read done: $c"
    if c.clientconnection
        t = @async monitor_idle_connection(c)
        @isdefined(errormonitor) && errormonitor(t)
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
    try
        close(c.io)
        if bytesavailable(c) > 0
            purge(c)
        end
    catch
        # ignore errors closing underlying socket
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

const TCP_POOL = Pool(Connection{Sockets.TCPSocket})
const MbedTLS_SSL_POOL = Pool(Connection{MbedTLS.SSLContext})
const OpenSSL_SSL_POOL = Pool(Connection{OpenSSL.SSLStream})
"""
    POOLS

A dict of global connection pools keeping track of active connections, split by their IO type.
"""
const POOLS = Dict{DataType,Pool}(
    Sockets.TCPSocket => TCP_POOL,
    MbedTLS.SSLContext => MbedTLS_SSL_POOL,
    OpenSSL.SSLStream => OpenSSL_SSL_POOL,
)
getpool(::Type{Sockets.TCPSocket}) = TCP_POOL
getpool(::Type{MbedTLS.SSLContext}) = MbedTLS_SSL_POOL
getpool(::Type{OpenSSL.SSLStream}) = OpenSSL_SSL_POOL
# Fallback for custom connection io types
# to opt out from locking, define your own `Pool` and add a `getpool` method for your IO type
const POOLS_LOCK = Threads.ReentrantLock()
function getpool(::Type{T}) where {T}
    Base.@lock POOLS_LOCK get!(() -> Pool(Connection{T}), POOLS, T)::Pool{Connection{T}}
end

"""
    closeall()

Close all connections in `POOLS`.
"""
closeall() = foreach(ConnectionPools.reset!, values(POOLS))

"""
    newconnection(type, host, port) -> Connection

Find a reusable `Connection` in the `pool`,
or create a new `Connection` if required.
"""
function newconnection(::Type{T},
                       host::AbstractString,
                       port::AbstractString;
                       connection_limit=default_connection_limit[],
                       forcenew::Bool=false,
                       idle_timeout=typemax(Int),
                       require_ssl_verification::Bool=NetworkOptions.verify_host(host, "SSL"),
                       kw...) where {T <: IO}
    return acquire(
            getpool(T),
            (T, host, port, require_ssl_verification, true);
            max_concurrent_connections=Int(connection_limit),
            forcenew=forcenew,
            idle_timeout=Int(idle_timeout)) do
        Connection(host, port,
            idle_timeout, require_ssl_verification,
            getconnection(T, host, port;
                require_ssl_verification=require_ssl_verification, kw...)
        )
    end
end

releaseconnection(c::Connection{T}, reuse) where {T} =
    release(getpool(T), connectionkey(c), c; return_for_reuse=reuse)

function keepalive!(tcp)
    Base.iolock_begin()
    Base.check_open(tcp)
    err = ccall(:uv_tcp_keepalive, Cint, (Ptr{Nothing}, Cint, Cuint),
                                          tcp.handle, 1, 1)
    Base.uv_error("failed to set keepalive on tcp socket", err)
    Base.iolock_end()
    return
end

struct ConnectTimeout <: Exception
    host
    port
end

function checkconnected(tcp)
    if tcp.status == Base.StatusConnecting
        close(tcp)
        return false
    end
    return true
end

function getconnection(::Type{TCPSocket},
                       host::AbstractString,
                       port::AbstractString;
                       # set keepalive to true by default since it's cheap and helps keep long-running requests/responses
                       # alive in the face of heavy workloads where Julia's task scheduler might take a while to
                       # keep up with midflight requests
                       keepalive::Bool=true,
                       connect_timeout::Int=10,
                       readtimeout::Int=0,
                       kw...)::TCPSocket

    p::UInt = isempty(port) ? UInt(80) : parse(UInt, port)
    @debugv 2 "TCP connect: $host:$p..."
    addrs = Sockets.getalladdrinfo(host)
    connect_timeout = connect_timeout == 0 && readtimeout > 0 ? readtimeout : connect_timeout
    lasterr = ErrorException("unknown connection error")

    for addr in addrs
        try
            return if connect_timeout > 0
                tcp = Sockets.TCPSocket()
                Sockets.connect!(tcp, addr, p)
                try_with_timeout(() -> checkconnected(tcp), connect_timeout, () -> close(tcp)) do
                    Sockets.wait_connected(tcp)
                    keepalive && keepalive!(tcp)
                end
                return tcp
            else
                tcp = Sockets.connect(addr, p)
                keepalive && keepalive!(tcp)
                tcp
            end
        catch e
            lasterr = e isa TimeoutError ? ConnectTimeout(host, port) : e
            continue
        end
    end
    # If no connetion could be set up, to any address, throw last error
    throw(lasterr)
end

const nosslconfig = SSLConfig()
const nosslcontext = Ref{OpenSSL.SSLContext}()
default_sslconfig = nothing
noverify_sslconfig = nothing

function global_sslconfig(require_ssl_verification::Bool)::SSLConfig
    global default_sslconfig
    global noverify_sslconfig
    if default_sslconfig === nothing
        default_sslconfig = SSLConfig(true)
        noverify_sslconfig = SSLConfig(false)
    end
    if haskey(ENV, "HTTP_CA_BUNDLE")
        MbedTLS.ca_chain!(default_sslconfig, MbedTLS.crt_parse(read(ENV["HTTP_CA_BUNDLE"], String)))
    elseif haskey(ENV, "CURL_CA_BUNDLE")
        MbedTLS.ca_chain!(default_sslconfig, MbedTLS.crt_parse(read(ENV["CURL_CA_BUNDLE"], String)))
    end
    return require_ssl_verification ? default_sslconfig : noverify_sslconfig
end

function global_sslcontext()::OpenSSL.SSLContext
    if isdefined(OpenSSL, :ca_chain!)
        if haskey(ENV, "HTTP_CA_BUNDLE")
            sslcontext = OpenSSL.SSLContext(OpenSSL.TLSClientMethod())
            OpenSSL.ca_chain!(sslcontext, ENV["HTTP_CA_BUNDLE"])
            return sslcontext
        elseif haskey(ENV, "CURL_CA_BUNDLE")
            sslcontext = OpenSSL.SSLContext(OpenSSL.TLSClientMethod())
            OpenSSL.ca_chain!(sslcontext, ENV["CURL_CA_BUNDLE"])
            return sslcontext
        end
    end
    return nosslcontext[]
end

function getconnection(::Type{SSLContext},
                       host::AbstractString,
                       port::AbstractString;
                       kw...)::SSLContext

    port = isempty(port) ? "443" : port
    @debugv 2 "SSL connect: $host:$port..."
    tcp = getconnection(TCPSocket, host, port; kw...)
    return sslconnection(SSLContext, tcp, host; kw...)
end

function getconnection(::Type{SSLStream},
    host::AbstractString,
    port::AbstractString;
    kw...)::SSLStream

    port = isempty(port) ? "443" : port
    @debugv 2 "SSL connect: $host:$port..."
    tcp = getconnection(TCPSocket, host, port; kw...)
    return sslconnection(SSLStream, tcp, host; kw...)
end

function sslconnection(::Type{SSLStream}, tcp::TCPSocket, host::AbstractString;
    require_ssl_verification::Bool=NetworkOptions.verify_host(host, "SSL"),
    sslconfig::OpenSSL.SSLContext=nosslcontext[],
    kw...)::SSLStream
    if sslconfig === nosslcontext[]
        sslconfig = global_sslcontext()
    end
    # Create SSL stream.
    ssl_stream = SSLStream(sslconfig, tcp)
    OpenSSL.hostname!(ssl_stream, host)
    OpenSSL.connect(ssl_stream; require_ssl_verification)
    return ssl_stream
end

function sslconnection(::Type{SSLContext}, tcp::TCPSocket, host::AbstractString;
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

function sslupgrade(::Type{IOType}, c::Connection{T},
                    host::AbstractString;
                    require_ssl_verification::Bool=NetworkOptions.verify_host(host, "SSL"),
                    readtimeout::Int=0,
                    kw...)::Connection{IOType} where {T, IOType}
    # initiate the upgrade to SSL
    # if the upgrade fails, an error will be thrown and the original c will be closed
    # in ConnectionRequest
    tls = if readtimeout > 0
        try_with_timeout(() -> shouldtimeout(c, readtimeout), readtimeout, () -> close(c)) do
            sslconnection(IOType, c.io, host; require_ssl_verification=require_ssl_verification, kw...)
        end
    else
        sslconnection(IOType, c.io, host; require_ssl_verification=require_ssl_verification, kw...)
    end
    # success, now we turn it into a new Connection
    conn = Connection(host, "", 0, require_ssl_verification, tls)
    # release the "old" one, but don't allow reuse since we're hijacking the socket
    release(getpool(T), connectionkey(c), c; return_for_reuse=false)
    # and return the new one
    return acquire(getpool(IOType), connectionkey(conn), conn)
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
        applicable(tcpsocket, c.io) ? " $(Base._fd(tcpsocket(c.io)))" : "")
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

function __init__()
    nosslcontext[] = OpenSSL.SSLContext(OpenSSL.TLSClientMethod())
    return
end

end # module ConnectionPool
