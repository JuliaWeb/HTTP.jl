module IOExtras

export unread!, closeread, closewrite

"""
    unread!(::IO, bytes)

Push bytes back into a connection (to be returned by the next read).
"""

function unread!(io, bytes)
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
