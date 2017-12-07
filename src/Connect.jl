module Connect

export getconnection, readresponse!, unread!

using MbedTLS: SSLConfig, SSLContext, setup!, associate!, hostname!, handshake!


function getconnection(::Type{TCPSocket}, host::String, port::UInt)
    connect(getaddrinfo(host), port)
end

function getconnection(::Type{SSLContext}, host::String, port::UInt)
    io = SSLContext()
    setup!(io, SSLConfig(false))
    associate!(io, connect(getaddrinfo(host), port))
    hostname!(io, host)
    handshake!(io)
    return io
end


"""
    readresponse!(io, response)

Read into `response`.
"""

readresponse!(io, response) = read!(io, response)


"""
    unread!(::Connection, bytes)

Push bytes back into a connection (to be returned by the next read).
"""

function unread!(io, bytes)
    println("WARNING: No unread! method for $(typeof(io))!")
    println("         Discarding $(length(bytes)) bytes!")
end

end # module Connect
