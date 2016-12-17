"""
escapeHTML(i::String)

Returns a string with special HTML characters escaped: &, <, >, ", '
"""
function escapeHTML(i::String)
    # Refer to http://stackoverflow.com/a/7382028/3822752 for spec. links
    o = replace(i, "&", "&amp;")
    o = replace(o, "\"", "&quot;")
    o = replace(o, "'", "&#39;")
    o = replace(o, "<", "&lt;")
    o = replace(o, ">", "&gt;")
    return o
end

"""
@timeout secs expr then pollint

Start executing `expr`; if it doesn't finish executing in `secs` seconds,
then execute `then`. `pollint` controls the amount of time to wait in between
checking if `expr` has finished executing (short for polling interval).
"""
macro timeout(t, expr, then, pollint=0.01)
    return quote
        tm = Float64($t)
        start = time()
        tsk = @async $expr
        while !istaskdone(tsk) && (time() - start < tm)
            sleep($pollint)
        end
        istaskdone(tsk) || $then
        tsk.result
    end
end

# FIFOBuffer: a fixed-size, first-in, first-out in-memory IO buffer type
# that prevents writes when full, but notifies its condition when space frees up for more writing
type FIFOBuffer <: IO
    len::Int # length of buffer in bytes
    max::Int # the max size buffer is allowed to grow to
    nb::Int  # number of bytes available to read in buffer
    f::Int   # buffer index that should be read next, unless nb == 0, then buffer is empty
    l::Int   # buffer index that should be written to next, unless nb == len, then buffer is full
    buffer::Vector{UInt8}
    cond::Condition
    eof::Bool
end

FIFOBuffer(n, max=n) = FIFOBuffer(n, max, 0, 1, 1, zeros(UInt8, n), Condition(), false)
FIFOBuffer() = FIFOBuffer(0, typemax(Int))

Base.length(f::FIFOBuffer) = f.nb
Base.wait(f::FIFOBuffer) = wait(f.cond)
Base.eof(f::FIFOBuffer) = f.eof

# 0 | 1 | 2 | 3 | 4 | 5 |
#---|---|---|---|---|---|
#   |f/l| _ | _ | _ | _ | empty, f == l, nb = 0, can't read, can write from l to l-1, don't need to change f, l = l, nb = len
#   | _ | _ |f/l| _ | _ | empty, f == l, nb = 0, can't read, can write from l:end, 1:l-1, don't need to change f, l = l, nb = len
#   | _ | f | x | l | _ | where f < l, can read f:l-1, then set f = l, can write l:end, 1:f-1, then set l = f, nb = len
#   | l | _ | _ | f | x | where l < f, can read f:end, 1:l-1, can write l:f-1, then set l = f
#   |f/l| x | x | x | x | full l == f, nb = len, can read f:l-1, can't write
#   | x | x |f/l| x | x | full l == f, nb = len, can read f:end, 1:l-1, can't write
function Base.read(f::FIFOBuffer, ::Type{UInt8})
    f.nb == 0 && return 0x00, false
    # data to read
    @inbounds b = f.buffer[f.f]
    f.f = mod1(f.f + 1, f.len)
    f.nb -= 1
    notify(f.cond)
    return b, true
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

function Base.readavailable(f::FIFOBuffer)
    # no data to read
    f.nb == 0 && return UInt8[]
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

function Base.write(f::FIFOBuffer, b::UInt8)
    # buffer full, check if we can grow it
    if f.nb == f.len
        if f.len < f.max
            append!(f.buffer, zeros(UInt8, min(f.len * 2, f.max)))
            f.len = length(f.buffer)
        else
            return 0
        end
    end
    # write our byte
    @inbounds f.buffer[f.l] = b
    f.l = mod1(f.l + 1, f.len)
    f.nb += 1
    notify(f.cond)
    return 1
end

function Base.write(f::FIFOBuffer, bytes::Vector{UInt8})
    # buffer full, check if we can grow it
    len = length(bytes)
    if f.nb == f.len
        if f.len < f.max
            append!(f.buffer, zeros(UInt8, min(len, f.max - f.len)))
            f.len = length(f.buffer)
        else
            return 0
        end
    end
    if f.f <= f.l
        diff = f.len - f.l + 1
        if len > diff
            # need to wrap around, and check if there's enough room to write full bytes
            # write `diff` # of bytes to end of buffer
            unsafe_copy!(f.buffer, f.l, bytes, 1, diff)
            if len - diff < f.f
                # there's enough room to write the rest of bytes
                unsafe_copy!(f.buffer, 1, bytes, diff + 1, len - diff)
                f.l = len - diff
            else
                # not able to write all of bytes
                unsafe_copy!(f.buffer, 1, bytes, diff + 1, f.f - 1)
                f.l = f.f
                f.nb += diff + f.f - 1
                notify(f.cond)
                return diff + f.f - 1
            end
        else
            # there's enough room to write bytes through the end of the buffer
            unsafe_copy!(f.buffer, f.l, bytes, 1, len)
            f.l = mod1(f.l + len, f.len)
        end
    else
        # already in wrap-around state
        if len > f.f - f.l
            # not able to write all of bytes
            unsafe_copy!(f.buffer, 1, bytes, 1, f.f - f.l)
            f.l = f.f
            f.nb += f.f - f.l
            notify(f.cond)
            return f.f - f.l
        else
            # there's enough room to write bytes
            unsafe_copy!(f.buffer, f.l, bytes, 1, len)
            f.l += len
        end
    end
    f.nb += len
    notify(f.cond)
    return len
end

# fixed size
# starts reading body off the wire into FIFOBuffer
# track start of data, end of data
# read from start of data
# write at end of data
# if hit end of buffer, wrap around to beginning

# on_headers_complete, async read bytes off the wire & pass to http-parser => FIFOBuffer
# when FIFOBuffer is full, we wait(f.condition)
# meanwhile, user can call read(::FIFOBuffer), which calls notify(f.cond)
# this wakes the async_reader back up and it continues filling the FIFOBuffer
# async_read finishes when eof(tcp) or messagecomplete and all body bytes have been written
# user can then finish reading FIFOBuffer as desired

# if user doesn't want streaming response body, keep resizing FIFOBuffer bigger until done

# try to benchmark the overhead of current setup (get entire body before finishing)
# vs. the async method w/ FIFOBuffer

# need decent API for getting body out of FIFOBuffer
