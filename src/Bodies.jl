module Bodies

export Body, isstream, isstreamfresh


"""
    Body

Represents a HTTP Message Body.

- `stream::IO`
- `buffer::IOBuffer`
- `length::Int`

If `stream` is set to `notastream`, then `buffer` contains static Message Body data.
Otherwise, `stream` is a stream to/from which Message Body data is written/read.
In streaming mode: `length` keeps track of the number of bytes that have passed
through `stream`; and `buffer` keeps a cache of the first part of the Message Body
(for display purposes). See `show` and `set_show_max`).
"""

mutable struct Body
    stream::IO
    buffer::IOBuffer
    length::Int
end

const notastream = IOBuffer("")
const unknownlength = -1


"""
    Body()
    Body(data [, length])
    Body(::IO, [, length])

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
Request Messages or Response Messages. `write(io, ::Body)` reads data from
the `Body`'s stream and writes it to `io`. `write(::Body, data)` writes
data from to the `Body`'s stream.

If `length` is unknown, `write(io, body)` uses chunked Transfer-Encoding.

e.g. Send a Request Body using chunked Transfer-Encoding:

```
io = open("bigfile.dat", "r")
write(socket, Body(io))
```

e.g. Send a Request Body with known length:

```
io = open("bigfile.dat", "r")
write(socket, Body(io, filesize("bigfile.dat")))
```

e.g. Send a Response Body to a stream:

```
io = open("response_file", "w")
b = Body(io)
while !eof(socket)
    write(b, readavailable(socket))
end
```
"""

Body() = Body(notastream, IOBuffer(), unknownlength)
Body(buffer::IOBuffer, l=unknownlength) = Body(notastream, buffer, l)
Body(stream::IO, l=unknownlength) = Body(stream, IOBuffer(body_show_max), l)
Body(::Void) = Body()
Body(data, l=unknownlength) = Body(IOBuffer(data), l)


"""
    isstream(::Body)

Is this `Body` in streaming mode?
"""

isstream(b::Body) = b.stream != notastream


"""
    isstreamfresh(::Body)

False if there have been any reads/writes from/to the `Body`'s stream.
"""

isstreamfresh(b::Body) = !isstream(b) || position(b.buffer) == 0



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
        close(body.stream)
        body.stream = notastream
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


"""
    write(::IO, ::Body)
    
Write data from `Body`'s `buffer` or `stream` to an `IO` stream,
"""

function Base.write(io::IO, body::Body)

    if !isstream(body)
        if VERSION > v"0.7.0-DEV.2338"
            bytes = view(body.buffer.data, 1:body.buffer.size)
        else
            bytes = body.buffer.data[1:body.buffer.size]
        end
        write(io, bytes)
        return
    end

    @assert isstreamfresh(body)

    # Use "chunked" encoding if length is unknown.
    # https://tools.ietf.org/html/rfc7230#section-4.1
    if body.length == unknownlength
        writechunked(io, body)
        return
    end

    # Read from `body.io` until `eof`, write to `io`.
    while !eof(body.stream)
        v = readavailable(body.stream)
        if body.buffer.size < body_show_max
            write(body.buffer, v)
        end
        write(io, v)
    end
    return
end


function writechunked(io::IO, body::Body)
    while !eof(body.stream)
        v = readavailable(body.stream)
        if body.buffer.size < body_show_max
            write(body.buffer, v)
        end
        write(io, hex(length(v)), "\r\n", v, "\r\n")
    end
    write(io, "0\r\n\r\n")
    return
end


"""
    write(::Body, data)
    
Write data to the `Body`'s `stream`,
or append it to the `Body`'s `buffer`.
"""

function Base.write(body::Body, v)

    if !isstream(body)
        return write(body.buffer, v)
    end

    if body.length < body_show_max
        write(body.buffer, v)
    end
    n = write(body.stream, v)
    body.length += n 
    return n
end


function Base.close(body::Body) 
    if isstream(body)
        close(body.stream)
    else
        body.buffer.writable = false
    end
end

Base.isopen(body::Body) =
    isstream(body) ? isopen(body.stream) : iswriteable(body.buffer)


"""
    set_show_max(x)

Set the maximum number of bytes to be displayed by `show(::IO, ::Body)`
"""

set_show_max(x) = global body_show_max = x
body_show_max = 1000


"""
    head(::Body)

The first chunk of the `Body` data (for display purposes).
"""
head(b::Body) = view(b.buffer.data, 1:min(b.buffer.size, body_show_max))

function Base.show(io::IO, body::Body)
    bytes = head(body)
    write(io, bytes)
    println(io, "")
    if isstream(body) && isopen(body.stream)
        println(io, "⋮\nWaiting for $(typeof(body.stream))...")
    elseif length(body) > length(bytes)
        println(io, "⋮\n$(length(body))-byte body")
    elseif length(body) == unknownlength
        println(io, "⋮\nlength unknown (chunked)")
    end
end


end #module Bodies
