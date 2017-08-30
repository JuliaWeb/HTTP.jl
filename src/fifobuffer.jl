module FIFOBuffers

import Base.==

export FIFOBuffer

"""
    FIFOBuffer([max::Integer])
    FIFOBuffer(string_or_bytes_vector)
    FIFOBuffer(io::IO)

A `FIFOBuffer` is a first-in, first-out, in-memory, async-friendly IO buffer type.

`FIFOBuffer([max])`: creates a "open" `FIFOBuffer` with a maximum size of `max`; this means that bytes can be written
up until `max` number of bytes have been written (with none being read). At this point, the `FIFOBuffer` is full
and will return 0 for all subsequent writes. If no `max` (`FIFOBuffer()`) argument is given, then a default size of `typemax(Int32)^2` is used;
this essentially allows all writes every time. Note that providing a string or byte vector argument mirrors the behavior of `Base.IOBuffer`
in that the `max` size of the `FIFOBuffer` is the length of the string/byte vector; it is also not writeable.

Reading is supported via `readavailable(f)` and `read(f, nb)`, which returns all or `nb` bytes, respectively, starting at the earliest bytes written.
All read functions will return an empty byte vector, even if the buffer has been closed. Checking `eof` will correctly reflect when the buffer has
been closed and no more bytes will be available for reading.

You may call `String(f::FIFOBuffer)` to view the current contents in the buffer without consuming them.

A `FIFOBuffer` is built to be used asynchronously to allow buffered reading and writing. In particular, a `FIFOBuffer`
detects if it is being read from/written to the main task, or asynchronously, and will behave slightly differently depending on which.

Specifically, when reading from a `FIFOBuffer`, if accessed from the main task, it will not block if there are no bytes available to read, instead returning an empty `UInt8[]`.
If being read from asynchronously, however, reading will block until additional bytes have been written. An example of this in action is:

```julia
f = HTTP.FIFOBuffer(5) # create a FIFOBuffer that will hold at most 5 bytes, currently empty
f2 = HTTP.FIFOBuffer(5) # a 2nd buffer that we'll write to asynchronously

# start an asynchronous writing task with the 2nd buffer
tsk = @async begin
    while !eof(f)
        write(f2, readavailable(f))
    end
end

# now write some bytes to the first buffer
# writing triggers our async task to wake up and read the bytes we just wrote
# leaving the first buffer empty again and blocking again until more bytes have been written
write(f, [0x01, 0x02, 0x03, 0x04, 0x05])

# we can see that `f2` now holds the bytes we wrote to `f`
String(readavailable(f2))

# our async task will continue until `f` is closed
close(f)

istaskdone(tsk) # true
```
"""
mutable struct FIFOBuffer <: IO
    len::Int64 # length of buffer in bytes
    max::Int64 # the max size buffer is allowed to grow to
    nb::Int64  # number of bytes available to read in buffer
    f::Int64   # buffer index that should be read next, unless nb == 0, then buffer is empty
    l::Int64   # buffer index that should be written to next, unless nb == len, then buffer is full
    buffer::Vector{UInt8}
    cond::Condition
    task::Task
    eof::Bool
end

const DEFAULT_MAX = Int64(typemax(Int32))^Int64(2)

FIFOBuffer(f::FIFOBuffer) = f
FIFOBuffer(max) = FIFOBuffer(0, max, 0, 1, 1, UInt8[], Condition(), current_task(), false)
FIFOBuffer() = FIFOBuffer(DEFAULT_MAX)

const EMPTYBODY = FIFOBuffer()

FIFOBuffer(str::String) = FIFOBuffer(Vector{UInt8}(str))
function FIFOBuffer(bytes::Vector{UInt8})
    len = length(bytes)
    return FIFOBuffer(len, len, len, 1, 1, bytes, Condition(), current_task(), true)
end
FIFOBuffer(io::IOStream) = FIFOBuffer(read(io))
FIFOBuffer(io::IO) = FIFOBuffer(readavailable(io))

==(a::FIFOBuffer, b::FIFOBuffer) = String(a) == String(b)
Base.length(f::FIFOBuffer) = f.nb
Base.nb_available(f::FIFOBuffer) = f.nb
Base.wait(f::FIFOBuffer) = wait(f.cond)
Base.read(f::FIFOBuffer) = readavailable(f)
Base.flush(f::FIFOBuffer) = nothing
Base.position(f::FIFOBuffer) = f.f, f.l, f.nb
function Base.seek(f::FIFOBuffer, pos::Tuple{Int64, Int64, Int64})
    f.f = pos[1]
    f.l = pos[2]
    f.nb = pos[3]
    return
end

Base.eof(f::FIFOBuffer) = f.eof && f.nb == 0
Base.isopen(f::FIFOBuffer) = !f.eof
function Base.close(f::FIFOBuffer)
    f.eof = true
    notify(f.cond)
    return
end

# 0 | 1 | 2 | 3 | 4 | 5 |
#---|---|---|---|---|---|
#   |f/l| _ | _ | _ | _ | empty, f == l, nb = 0, can't read, can write from l to l-1, don't need to change f, l = l, nb = len
#   | _ | _ |f/l| _ | _ | empty, f == l, nb = 0, can't read, can write from l:end, 1:l-1, don't need to change f, l = l, nb = len
#   | _ | f | x | l | _ | where f < l, can read f:l-1, then set f = l, can write l:end, 1:f-1, then set l = f, nb = len
#   | l | _ | _ | f | x | where l < f, can read f:end, 1:l-1, can write l:f-1, then set l = f
#   |f/l| x | x | x | x | full l == f, nb = len, can read f:l-1, can't write
#   | x | x |f/l| x | x | full l == f, nb = len, can read f:end, 1:l-1, can't write
function Base.readavailable(f::FIFOBuffer)
    # no data to read
    if f.nb == 0
        if current_task() == f.task || f.eof
            return UInt8[]
        else # async + still open: block till there's data to read
            wait(f.cond)
            f.nb == 0 && return UInt8[]
        end
    end
    if f.f < f.l
        @inbounds bytes = f.buffer[f.f:f.l-1]
    else
        # we've wrapped around
        @inbounds bytes = f.buffer[f.f:end]
        @inbounds append!(bytes, view(f.buffer, 1:f.l-1))
    end
    f.f = f.l
    f.nb = 0
    notify(f.cond)
    return bytes
end

# read at most `nb` bytes
function Base.read(f::FIFOBuffer, nb::Int)
    # no data to read
    if f.nb == 0
        if current_task() == f.task || f.eof
            return UInt8[]
        else # async: block till there's data to read
            wait(f.cond)
            f.nb == 0 && return UInt8[]
        end
    end
    if f.f < f.l
        l = (f.l - f.f) <= nb ? (f.l - 1) : (f.f + nb - 1)
        @inbounds bytes = f.buffer[f.f:l]
        f.f = mod1(l + 1, f.max)
    else
        # we've wrapped around
        if nb <= (f.len - f.f + 1)
            # we can read all we need between f.f and f.len
            @inbounds bytes = f.buffer[f.f:(f.f + nb - 1)]
            f.f = mod1(f.f + nb, f.max)
        else
            @inbounds bytes = f.buffer[f.f:f.len]
            l = min(f.l - 1, nb - length(bytes))
            @inbounds append!(bytes, view(f.buffer, 1:l))
            f.f = mod1(l + 1, f.max)
        end
    end
    f.nb -= length(bytes)
    notify(f.cond)
    return bytes
end

function Base.read(f::FIFOBuffer, ::Type{Tuple{UInt8,Bool}})
    # no data to read
    if f.nb == 0
        if current_task() == f.task || f.eof
            return 0x00, false
        else # async: block till there's data to read
            f.eof && return 0x00, false
            wait(f.cond)
            f.nb == 0 && return 0x00, false
        end
    end
    # data to read
    @inbounds b = f.buffer[f.f]
    f.f = mod1(f.f + 1, f.max)
    f.nb -= 1
    notify(f.cond)
    return b, true
end

function Base.read(f::FIFOBuffer, ::Type{UInt8})
    byte, valid = read(f, Tuple{UInt8,Bool})
    valid || throw(EOFError())
    return byte
end

function Base.String(f::FIFOBuffer)
    f.nb == 0 && return ""
    if f.f < f.l
        return String(f.buffer[f.f:f.l-1])
    else
        bytes = f.buffer[f.f:end]
        append!(bytes, view(f.buffer, 1:f.l-1))
        return String(bytes)
    end
end

function Base.write(f::FIFOBuffer, b::UInt8)
    # buffer full, check if we can grow it
    if f.nb == f.len || f.len < f.l
        if f.len < f.max
            push!(f.buffer, 0x00)
            f.len += 1
        else
            if current_task() == f.task || f.eof
                return 0
            else # async: block until there's room to write
                wait(f.cond)
                f.nb == f.len && return 0
            end
        end
    end
    # write our byte
    @inbounds f.buffer[f.l] = b
    f.l = mod1(f.l + 1, f.max)
    f.nb += 1
    notify(f.cond)
    return 1
end

function Base.write(f::FIFOBuffer, bytes::Vector{UInt8}, i, j)
    len = j - i + 1
    if f.nb == f.len || f.len < f.l
        # buffer full, check if we can grow it
        if f.len < f.max
            append!(f.buffer, zeros(UInt8, min(len, f.max - f.len)))
            f.len = length(f.buffer)
        else
            if current_task() == f.task || f.eof
                return 0
            else # async: block until there's room to write
                wait(f.cond)
                f.nb == f.len && return 0
            end
        end
    end
    if f.f <= f.l
        # non-wraparound
        avail = f.len - f.l + 1
        if len > avail
            # need to wrap around, and check if there's enough room to write full bytes
            # write `avail` # of bytes to end of buffer
            unsafe_copy!(f.buffer, f.l, bytes, i, avail)
            if len - avail < f.f
                # there's enough room to write the rest of bytes
                unsafe_copy!(f.buffer, 1, bytes, avail + 1, len - avail)
                f.l = len - avail + 1
            else
                # not able to write all of bytes
                unsafe_copy!(f.buffer, 1, bytes, avail + 1, f.f - 1)
                f.l = f.f
                f.nb += avail + f.f - 1
                notify(f.cond)
                return avail + f.f - 1
            end
        else
            # there's enough room to write bytes through the end of the buffer
            unsafe_copy!(f.buffer, f.l, bytes, i, len)
            f.l = mod1(f.l + len, f.max)
        end
    else
        # already in wrap-around state
        if len > mod1(f.f - f.l, f.max)
            # not able to write all of bytes
            nb = f.f - f.l
            unsafe_copy!(f.buffer, f.l, bytes, i, nb)
            f.l = f.f
            f.nb += nb
            notify(f.cond)
            return nb
        else
            # there's enough room to write bytes
            unsafe_copy!(f.buffer, f.l, bytes, i, len)
            f.l  = mod1(f.l + len, f.max)
        end
    end
    f.nb += len
    notify(f.cond)
    return len
end

Base.write(f::FIFOBuffer, bytes::Vector{UInt8}) = write(f, bytes, 1, length(bytes))
Base.write(f::FIFOBuffer, str::String) = write(f, Vector{UInt8}(str))

end # module