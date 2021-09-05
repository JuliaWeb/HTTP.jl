"""
    _precompile_()

Run some tiny workloads that the package should precompile.
"""
function _precompile_()
    VERSION < v"1.5" && return nothing
    try
        HTTP.get("http://127.0.0.1"; connect_timeout=1, retry=false)
    catch
    end
end
