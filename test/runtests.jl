using Test, HTTP, URIs, JSON

const httpbin = get(ENV, "JULIA_TEST_HTTPBINGO_SERVER", "httpbingo.julialang.org")
isok(r) = r.status == 200

# Core.eval(Base, :(function unsafe_copyto!(dest::Base.MemoryRef{T}, src::Base.MemoryRef{T}, n) where {T}
#     Base.@_terminates_globally_notaskstate_meta
#     n == 0 && return dest
#     @show n
#     @boundscheck Base.memoryref(dest, n), Base.memoryref(src, n)
#     if isbitstype(T)
#         tdest = Base.@_gc_preserve_begin dest
#         tsrc = Base.@_gc_preserve_begin src
#         pdest = unsafe_convert(Ptr{Cvoid}, dest)
#         psrc = unsafe_convert(Ptr{Cvoid}, src)
#         Base.memmove(pdest, psrc, Base.aligned_sizeof(T) * n)
#         Base.@_gc_preserve_end tdest
#         Base.@_gc_preserve_end tsrc
#     else
#         ccall(:jl_genericmemory_copyto, Cvoid, (Any, Ptr{Cvoid}, Any, Ptr{Cvoid}, Int), dest.mem, dest.ptr_or_offset, src.mem, src.ptr_or_offset, Int(n))
#     end
#     return dest
# end))

include("utils.jl")
include("sniff.jl")
include("multipart.jl")
include("client.jl")
include("handlers.jl")
include("server.jl")
