"""
    _precompile_()

Run some tiny workloads that the package should precompile.
"""
function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    VERSION < v"1.5" && return nothing

    try
        r = HTTP.get("http://127.0.0.1"; connect_timeout=1, retry=false)
        io = IOBuffer()
        show(io, r)
    catch
    end
end
