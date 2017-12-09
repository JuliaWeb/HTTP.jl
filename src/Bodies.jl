module Bodies

export Body, isstream


"""
    set_show_max(x)

Set the maximum number of bytes to be displayed by `show(::IO, ::Body)`
"""

set_show_max(x) = global body_show_max = x
body_show_max = 1000


"""
    Body

Represents a HTTP Message Body.

If `io` is set to `notastream`, then `buffer` contains static Message Body data.
Otherwise, `io` is a stream to/from which Message Body data is written/read.
In streaming mode: `length` keeps track of the number of bytes that have passed
through `io`; and `buffer` keeps a cache of the first part of the Message Body
(for display purposes). See `show` and `set_show_max`).
"""

mutable struct Body
    io::IO
    buffer::IOBuffer
    length::Int
end

const notastream = IOBuffer("")


"""
    Body()
    Body(data)
    Body(::IO)

`Body()` creates an empty HTTP Message `Body` buffer.
The `write(::Body)` function can be used to append data to the empty `Body`.
The `write(::IO)` function can then be used to send the Body to an `IO` stream.
e.g.

```
b = Body()
write(b, "Hello\\n")
write(b, "World!\\n")
write(socket, b)
```

`Body(data)` creates a `Body` with fixed content.

`Body(::IO)` creates a streaming mode `Body`. This can be used to stream either
Request Messages or Response Messages. `write(io, body)` reads data from
the `body`'s stream and writes it to the `io` target. `write(body, data)` writes
data to the `body`'s stream.
"""

Body(::Void) = Body()
Body(buffer::IOBuffer=IOBuffer()) = Body(notastream, buffer, 0)
Body(io::IO) = Body(io, IOBuffer(body_show_max), 0)
Body(data) = Body(IOBuffer(data))


"""
    isstream(::Body)

Is this `Body` in streaming mode?
"""

isstream(b::Body) = b.io != notastream


"""
    length(::Body)

Number of bytes in the body.
In streaming mode, number of bytes that have passed through the stream.
"""

Base.length(b::Body) = isstream(b) ? b.length : b.buffer.size


"""
    collect!(::Body)

If the `Body` is in streaming mode, read the complete content of the stream
into the local buffer then close the stream.
Returns a `view` of the local buffer.
"""

function collect!(body::Body)
    if isstream(body)
        io = IOBuffer()
        write(io, body)
        body.buffer = io
        close(body.io)
        body.io = notastream
    end
    @assert !isstream(body)
    return view(body.buffer.data, 1:body.buffer.size)
end


"""
    take!(::Body)

Obtain the contents of `Body` and clear the internal buffer.
"""

function Base.take!(body::Body)
    collect!(body)
    take!(body.buffer)
end

function Base.write(io::IO, body::Body)

    if !isstream(body)
        return write(io, view(body.buffer.data, 1:body.buffer.size))
    end

    # Read from `body.io` until `eof`, 
    # write to `io` using "chunked" encoding.
    # https://tools.ietf.org/html/rfc7230#section-4.1
    @assert body.length == 0
    @assert position(body.buffer) == 0
    while !eof(body.io)
        v = readavailable(body.io)
        l = length(v)
        if body.length < body_show_max
            write(body.buffer, v)
        end
        write(io, hex(l), "\r\n", v, "\r\n")
        body.length += l
    end
    write(io, "0\r\n\r\n")
    return body.length
end

function Base.write(body::Body, v)

    if !isstream(body)
        return write(body.buffer, v)
    end

    if body.length < body_show_max
        write(body.buffer, v)
    end
    n = write(body.io, v)
    body.length += n 
    return n
end

Base.close(body::Body) = if isstream(body); close(body.io) end


"""
    head(::Body)

The first chunk of the `Body` data (for display purposes).
"""
head(b::Body) = view(b.buffer.data, 1:min(b.buffer.size, body_show_max))

function Base.show(io::IO, body::Body)
    bytes = head(body)
    write(io, bytes)
    println(io, "")
    if isstream(body) && isopen(body.io)
        println(io, "⋮\nWaiting for $(typeof(body.io))...")
    elseif length(body) > length(bytes)
        println(io, "⋮\n$(length(body))-byte body")
    end
end

end #module Bodies
