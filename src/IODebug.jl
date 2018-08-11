const live_mode = true

import ..debug_header

@static if live_mode

    struct IODebug{T <: IO} <: IO
        io::T
    end

    logwrite(iod::IODebug, x) = show_io_debug(stdout, "➡️ ", x)
    logread(iod::IODebug, x) = show_io_debug(stdout, "⬅️ ", x)
    logunread(iod::IODebug, x) = show_io_debug(stdout, "♻️ ", x)

else

    struct IODebug{T <: IO} <: IO
        io::T
        log::Vector{Tuple{String,String}}
    end

    IODebug(io::T) where T <: IO = IODebug{T}(io, [])

    logwrite(iod::IODebug, x) = push!(iod.log, ("➡️ ", x))
    logread(iod::IODebug, x) = push!(iod.log, ("⬅️ ", x))
    logunread(iod::IODebug, x) = push!(iod.log, ("♻️ ", x))

end
 
Base.write(iod::IODebug, a...) = (logwrite(iod, join(a)); write(iod.io, a...))

Base.write(iod::IODebug, x::String) = (logwrite(iod, x); write(iod.io, x))

Base.unsafe_write(iod::IODebug, x::Ptr{UInt8}, n::UInt) =
    (logwrite(iod, unsafe_string(x,n));
     unsafe_write(iod.io, x, n))

Base.read(iod::IODebug, n::Integer) =
    (r = read(iod.io, n);
     logread(iod, String(r)); r)

Base.readavailable(iod::IODebug) =
    (r = readavailable(iod.io);
     logread(iod, String(r)); r)

IOExtras.unread!(iod::IODebug, bytes) =
    (logunread(iod, String(bytes));
     unread!(iod.io, bytes))

Base.eof(iod::IODebug) = eof(iod.io)
Base.close(iod::IODebug) = close(iod.io)
Base.isopen(iod::IODebug) = isopen(iod.io)
Base.iswritable(iod::IODebug) = iswritable(iod.io)
Base.isreadable(iod::IODebug) = isreadable(iod.io)
IOExtras.startread(iod::IODebug) = startread(iod.io)
IOExtras.startwrite(iod::IODebug) = startwrite(iod.io)
IOExtras.closeread(iod::IODebug) = closeread(iod.io)
IOExtras.closewrite(iod::IODebug) = closewrite(iod.io)

Base.bytesavailable(iod::IODebug) = bytesavailable(iod.io)

Base.show(io::IO, iod::IODebug) = show(io, iod.io)

function show_log(io::IO, iod::IODebug)
    lock(io)
    println(io, "$(typeof(iod)):\nio:     $(iod.io)")
    prevop = ""
    for (operation, bytes) in iod.log
        if prevop != "" && prevop != operation
            println(io)
        end
        show_io_debug(io, operation, bytes)
        prevop = operation
    end
    println(io)
    unlock(io)
end


function show_io_debug(io::IO, operation, bytes)
    prefix = string(debug_header(), rpad(operation, 4))
    i = j = 1
    while i < length(bytes)
        j = findnext(bytes, '\n', i)
        if j == nothing || j == 0
            j = prevind(bytes, length(bytes)+1)
        end
        println(io, prefix, "\"", escape_string(bytes[i:j]), "\"")
        if i == 1
            prefix = rpad("DEBUG:", length(prefix) - 1)
        end
        i = nextind(bytes, j)
    end
end
