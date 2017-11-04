module FIFOBuffers

export FIFOBuffer

struct FIFOBuffer{T <: Union{IOBuffer,BufferStream}} <: IO
    io::T
end

FIFOBuffer() = FIFOBuffer{BufferStream}(BufferStream())
FIFOBuffer(bytes::Vector{UInt8}) = FIFOBuffer{IOBuffer}(IOBuffer(bytes))
FIFOBuffer(str::String) = FIFOBuffer{IOBuffer}(IOBuffer(str))

FIFOBuffer(io::IOStream) = FIFOBuffer(read(io))
FIFOBuffer(io::IO) = FIFOBuffer(readavailable(io))

FIFOBuffer(f::FIFOBuffer) = f

Base.String(f::FIFOBuffer{IOBuffer}) = String(f.io.data[f.io.ptr:f.io.size])
Base.String(f::FIFOBuffer{BufferStream}) = String(FIFOBuffer(f.io.buffer))

import Base.==
function ==(a::FIFOBuffer, b::FIFOBuffer)
    (nb_available(a) == 0 && nb_available(b) == 0) || String(a) == String(b)
end


Base.readavailable(f::FIFOBuffer) = readavailable(f.io)

# See issue #24465: "mark/reset broken for BufferStream"
# https://github.com/JuliaLang/julia/issues/24465
# So, need to reach down into IOBuffer for readavailable():
Base.readavailable(f::FIFOBuffer{BufferStream}) = readavailable(f.io.buffer)

Base.read(f::FIFOBuffer, a...) = read(f.io, a...)
Base.read(f::FIFOBuffer, ::Type{UInt8}) = read(f.io, UInt8)
Base.write(f::FIFOBuffer, bytes::Vector{UInt8}) = write(f.io, bytes)

map(eval, :(Base.$f(f::FIFOBuffer) = $f(f.io))
    for f in [:nb_available, :flush, :mark, :reset, :eof, :isopen, :close])

Base.length(f::FIFOBuffer) = nb_available(f)

function Base.read(f::FIFOBuffer, ::Type{Tuple{UInt8,Bool}})
    if nb_available(f.io) == 0
        return 0x00, false 
    end
    return read(f.io, UInt8), true
end

Base.write(f::FIFOBuffer{BufferStream}, x::UInt8) = write(f.io, [x])

Base.wait_readnb(f::FIFOBuffer{BufferStream}, nb::Int) = Base.wait_readnb(f.io, nb)


end # module
