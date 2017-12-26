module IOExtras

export unread!, closeread, closewrite

"""
    unread!(::IO, bytes)

Push bytes back into a connection (to be returned by the next read).
"""

function unread!(io::IOBuffer, bytes)
    l = length(bytes)
    if l == 0
        return
    end

    @assert bytes == io.data[io.ptr - l:io.ptr-1]

    if io.seekable
        seek(io, io.ptr - (l + 1))
        return
    end

    println("WARNING: Can't unread! non-seekable IOBuffer")
    println("         Discarding $(length(bytes)) bytes!")
    @assert false
    return
end

function unread!(io::BufferStream, bytes)
    if length(bytes) == 0
        return
    end
    if nb_available(io) > 0
        buf = readavailable(io)
        write(io, bytes)
        write(io, buf)
    else
        write(io, bytes)
    end
    return
end

function unread!(io, bytes)
    if length(bytes) == 0
        return
    end
    println("WARNING: No unread! method for $(typeof(io))!")
    println("         Discarding $(length(bytes)) bytes!")
end



"""
    closewrite(::IO)
    closeread(::IO)

Signal end of write or read operations.
"""

closewrite(io) = nothing
closeread(io) = close(io)


end
