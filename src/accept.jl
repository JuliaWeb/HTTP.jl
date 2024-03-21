
module Accept

export acceptmany

using Base: iolock_begin, iolock_end, uv_error, preserve_handle, unpreserve_handle,
    StatusClosing, StatusClosed, StatusActive, UV_EAGAIN, UV_ECONNABORTED
using Sockets

function acceptmany(server; MAXSIZE=Sockets.BACKLOG_DEFAULT)
    result = Vector{TCPSocket}()
    sizehint!(result, MAXSIZE)
    iolock_begin()
    if server.status != StatusActive && server.status != StatusClosing && server.status != StatusClosed
        throw(ArgumentError("server not connected, make sure \"listen\" has been called"))
    end
    while isopen(server)
        client = TCPSocket()
        err = Sockets.accept_nonblock(server, client)
        while err == 0 && length(result) < MAXSIZE  # Don't try to fill more than half the buffer
            push!(result, client)
            client = TCPSocket()
            err = Sockets.accept_nonblock(server, client)
        end
        if length(result) > 0
            iolock_end()
            return result
        end
        if err != UV_EAGAIN
            uv_error("accept", err)
        end
        preserve_handle(server)
        lock(server.cond)
        iolock_end()
        try
            wait(server.cond)
        finally
            unlock(server.cond)
            unpreserve_handle(server)
        end
        iolock_begin()
    end
    uv_error("accept", UV_ECONNABORTED)
    nothing
end

end