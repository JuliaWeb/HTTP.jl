
v06 = v"0.6.2"
v07 = v"0.7.0-alpha.0"

supported() = VERSION >= v07 ||
             (VERSION >= v06 && VERSION < v"0.7.0-DEV")

compat_warn() = warn("""
    HTTP.jl has not been tested with Julia version $VERSION
    Supported versions are $v06 and $v07 and above.
    """)

__init__() = supported() || compat_warn()

@static if VERSION >= v07

    using Base64
    import Dates

    const bytesavailable = Base.bytesavailable
    const compat_findfirst = Base.findfirst
    const compat_replace = Base.replace
    const compat_occursin = Base.occursin
    const compat_parse = Base.parse
    const compat_string = Base.string

    compat_stdout() = stdout

    compat_search(s::AbstractString, c::Char) = Base.findfirst(isequal(c), s)
    using Sockets

    sprintcompact(x) = sprint(show, x; context=:compact => true)

else

    supported() || compat_warn()

    eval(:(module Base64 end))
    const Dates = Base.Dates

    const bytesavailable = Base.nb_available
    compat_findfirst(a...) = (r = Base.findfirst(a...); r == 0 ? nothing : r)
    compat_replace(s, p) = Base.replace(s, p.first, p.second)
    compat_occursin(needle, haystack) = contains(haystack, needle)
    compat_parse(s, T; base::Int=10) = Base.parse(s, T, base)
    compat_string(s; base::Int=16, pad::Int=0) = hex(s, pad)

    compat_stdout() = STDOUT

    compat_search(s::AbstractString, c::Char) = compat_findfirst(s, c)

    const Nothing = Void
    const isnumeric = isnumber
    const isletter = isalpha

    Base.SubString(s) = SubString(s, 1)
    Base.String(x::SubArray{UInt8,1}) = String(Vector{UInt8}(x))

    macro debug(s) DEBUG_LEVEL > 0 ? :(("D- ", $(esc(s)))) : :() end
    macro info(s)  DEBUG_LEVEL >= 0 ? :(println("I- ", $(esc(s)))) : :() end
    macro warn(s)  DEBUG_LEVEL >= 0 ? :(println("W- ", $(esc(s)))) : :() end
    macro error(m, args...)
        args = [:(print("|  "); @show $a) for a in args]
        esc(:(println("E- ", $m); $(args...); nothing))
    end
    if !isdefined(Main, :Compat)
        Base.fetch(t::Task) = wait(t)
    end

    eval(:(module Sockets
        export TCPSocket
        import Base: TCPSocket, TCPServer, IPAddr, @ip_str, DNSError,
            getsockname, getaddrinfo, connect, listen, DNSError, InetAddr
        const localhost = ip"127.0.0.1"
        end))
    using .Sockets

    sprintcompact(x) = sprint(showcompact, x)
end

#https://github.com/JuliaWeb/MbedTLS.jl/issues/122
@static if !applicable(bytesavailable, MbedTLS.SSLContext())
    Base.bytesavailable(ssl::MbedTLS.SSLContext) = nb_available(ssl)
end
