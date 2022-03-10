import MbedTLS
const MbedTLS_jll = MbedTLS.MbedTLS_jll

function _precompile()

    if ccall(:jl_generating_output, Cint, ()) != 1
        return nothing
    end

    @static if Base.VERSION < v"1.9-"
        # We need https://github.com/JuliaLang/julia/pull/43990, otherwise this isn't worth doing.
        return nothing
    end

    precompile(Tuple{typeof(Base.:(!=)), UInt64, UInt64})
    precompile(Tuple{typeof(MbedTLS_jll.__init__)})
    precompile(Tuple{typeof(MbedTLS.f_send), Ptr{Nothing}, Ptr{UInt8}, UInt64})
    precompile(Tuple{typeof(MbedTLS.f_recv), Ptr{Nothing}, Ptr{UInt8}, UInt64})
    precompile(Tuple{typeof(MbedTLS.__init__)})
    precompile(Tuple{typeof(URIs.__init__)})
    precompile(Tuple{typeof(HTTP.Parsers.__init__)})
    precompile(Tuple{typeof(HTTP.CookieRequest.__init__)})
    precompile(Tuple{typeof(HTTP.ConnectionRequest.__init__)})
    precompile(Tuple{typeof(HTTP.Servers.__init__)})
    precompile(Tuple{typeof(HTTP.MultiPartParsing.__init__)})
    precompile(Tuple{typeof(HTTP.get), String})
    precompile(Tuple{Type{NamedTuple{(:init,), T} where T<:Tuple}, Tuple{DataType}})
    precompile(Tuple{Base.var"#reduce##kw", NamedTuple{(:init,), Tuple{DataType}}, typeof(Base.reduce), Function, Base.Set{Tuple{Union{Type{Union{}}, UnionAll}, UnionAll}}})
    precompile(Tuple{typeof(Base.mapfoldl_impl), typeof(Base.identity), HTTP.var"#24#25", Type, Base.Set{Tuple{Union{Type{Union{}}, UnionAll}, UnionAll}}})
    precompile(Tuple{typeof(HTTP.request), Type{HTTP.TopRequest.TopLayer{HTTP.RedirectRequest.RedirectLayer{HTTP.BasicAuthRequest.BasicAuthLayer{HTTP.MessageRequest.MessageLayer{HTTP.RetryRequest.RetryLayer{HTTP.ExceptionRequest.ExceptionLayer{HTTP.ConnectionRequest.ConnectionPoolLayer{HTTP.StreamRequest.StreamLayer{Union{}}}}}}}}}}, String, URIs.URI, Array{Pair{Base.SubString{String}, Base.SubString{String}}, 1}, Array{UInt8, 1}})
    precompile(Tuple{HTTP.var"#request##kw", NamedTuple{(:iofunction, :reached_redirect_limit), Tuple{Nothing, Bool}}, typeof(HTTP.request), Type{HTTP.ExceptionRequest.ExceptionLayer{HTTP.ConnectionRequest.ConnectionPoolLayer{HTTP.StreamRequest.StreamLayer{Union{}}}}}, URIs.URI, HTTP.Messages.Request, Array{UInt8, 1}})
    precompile(Tuple{HTTP.var"#request##kw", NamedTuple{(:iofunction, :reached_redirect_limit), Tuple{Nothing, Bool}}, typeof(HTTP.request), Type{HTTP.ConnectionRequest.ConnectionPoolLayer{HTTP.StreamRequest.StreamLayer{Union{}}}}, URIs.URI, HTTP.Messages.Request, Array{UInt8, 1}})
    precompile(Tuple{typeof(Sockets.uv_getaddrinfocb), Ptr{Nothing}, Int32, Ptr{Nothing}})
    precompile(Tuple{HTTP.ConnectionPool.var"#newconnection##kw", NamedTuple{(:iofunction, :reached_redirect_limit), Tuple{Nothing, Bool}}, typeof(HTTP.ConnectionPool.newconnection), Type{MbedTLS.SSLContext}, Base.SubString{String}, Base.SubString{String}})
    precompile(Tuple{typeof(Sockets.uv_connectcb), Ptr{Nothing}, Int32})
    precompile(Tuple{typeof(Sockets.connect), Sockets.IPv4, UInt64})
    precompile(Tuple{typeof(Base.setproperty!), Sockets.TCPSocket, Symbol, Int64})
    precompile(Tuple{typeof(Base.notify), Base.GenericCondition{Base.Threads.SpinLock}})
    precompile(Tuple{typeof(MbedTLS.f_rng), MbedTLS.CtrDrbg, Ptr{UInt8}, UInt64})
    precompile(Tuple{typeof(Base.isopen), Sockets.TCPSocket})
    precompile(Tuple{typeof(Base.getproperty), Sockets.TCPSocket, Symbol})
    precompile(Tuple{typeof(Base.unsafe_write), Sockets.TCPSocket, Ptr{UInt8}, UInt64})
    precompile(Tuple{typeof(Base.bytesavailable), Sockets.TCPSocket})
    precompile(Tuple{typeof(Base.eof), Sockets.TCPSocket})
    precompile(Tuple{typeof(Base.alloc_buf_hook), Sockets.TCPSocket, UInt64})
    precompile(Tuple{Base.var"#readcb_specialized#671", Sockets.TCPSocket, Int64, UInt64})
    precompile(Tuple{typeof(Base.min), UInt64, Int64})
    precompile(Tuple{typeof(Base.unsafe_read), Sockets.TCPSocket, Ptr{UInt8}, UInt64})
    precompile(Tuple{Type{Int32}, UInt64})
    precompile(Tuple{typeof(HTTP.Messages.hasheader), HTTP.Messages.Request, String})
    precompile(Tuple{typeof(HTTP.Messages.ischunked), HTTP.Messages.Request})
    precompile(Tuple{typeof(HTTP.Messages.writeheaders), Base.GenericIOBuffer{Array{UInt8, 1}}, HTTP.Messages.Request})
    precompile(Tuple{typeof(Base.unsafe_write), MbedTLS.SSLContext, Ptr{UInt8}, UInt64})
    precompile(Tuple{typeof(Base.check_open), Sockets.TCPSocket})
    precompile(Tuple{MbedTLS.var"#25#26"{MbedTLS.SSLContext}})
    precompile(Tuple{typeof(Base.eof), MbedTLS.SSLContext})
    precompile(Tuple{HTTP.StreamRequest.var"#2#3"{HTTP.ConnectionPool.Connection, HTTP.Messages.Request, Array{UInt8, 1}, HTTP.Streams.Stream{HTTP.Messages.Response, HTTP.ConnectionPool.Connection}}})
    precompile(Tuple{typeof(Base.bytesavailable), MbedTLS.SSLContext})
    precompile(Tuple{typeof(Base.unsafe_read), MbedTLS.SSLContext, Ptr{UInt8}, Int64})
    precompile(Tuple{typeof(Base.readuntil), Base.GenericIOBuffer{Array{UInt8, 1}}, typeof(HTTP.Parsers.find_end_of_header)})
    precompile(Tuple{typeof(Base.release), HTTP.ConnectionPool.ConnectionPools.Pool{HTTP.ConnectionPool.Connection}, Tuple{DataType, String, String, Bool, Bool}, HTTP.ConnectionPool.Connection})
    precompile(Tuple{typeof(Base.isequal), Tuple{DataType, String, String, Bool, Bool}, Tuple{DataType, Base.SubString{String}, Base.SubString{String}, Bool, Bool}})
    precompile(Tuple{typeof(Base.isopen), MbedTLS.SSLContext})
    precompile(Tuple{MbedTLS.var"#21#23"{MbedTLS.SSLContext}, MbedTLS.SSLContext})
    precompile(Tuple{MbedTLS.var"#15#16", MbedTLS.CRT})
    precompile(Tuple{MbedTLS.var"#10#11", MbedTLS.CtrDrbg})
    precompile(Tuple{MbedTLS.var"#8#9", MbedTLS.Entropy})
    precompile(Tuple{MbedTLS.var"#17#19", MbedTLS.SSLConfig})
    precompile(Tuple{typeof(Base.uvfinalize), Sockets.TCPSocket})

    return nothing
end

