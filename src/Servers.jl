module Servers

export listen

using Sockets, Dates, MbedTLS
using ..ConnectionPool, ..Parsers, ..IOExtras, ..Messages, ..Streams, ..Handlers

import ..Handlers.handle

# rate limiting
mutable struct RateLimit
    allowance::Float64
    lastcheck::Dates.DateTime
end

function update!(rl::RateLimit, ratelimit)
    current = Dates.now()
    timepassed = float(Dates.value(current - rl.lastcheck)) / 1000.0
    rl.lastcheck = current
    rl.allowance += timepassed * ratelimit
    return nothing
end

const RATE_LIMITS = Dict{IPAddr, RateLimit}()
check_rate_limit(tcp::Base.PipeEndpoint; kw...) = true
function check_rate_limit(tcp, ratelimit::Rational{Int})
    ip = Sockets.getsockname(tcp)[1]
    rate = Float64(ratelimit.num)
    rl = get!(RATE_LIMITS, ip, RateLimit(rate, Dates.now()))
    update!(rl, ratelimit)
    if rl.allowance > rate
        @warn "throttling $ip"
        rl.allowance = rate
    end
    if rl.allowance < 1.0
        @warn "discarding connection from $ip due to rate limiting"
        return false
    else
        rl.allowance -= 1.0
    end
    return true
end

function handle(h::Handler, t::Transaction, last::Bool=false)
    request = Request()
    stream = Stream(request, t)

    try
        startread(stream)
    catch e
        if e isa EOFError && isempty(request.method)
            return
        elseif e isa ParseError
            status = e.code == :HEADER_SIZE_EXCEEDS_LIMIT  ? 413 : 400
            write(t, Response(status, body = string(e.code)))
            close(t)
            return
        else
            rethrow(e)
        end
    end

    request.response.status = 200
    (last || hasheader(request, "Connection", "close")) &&
        setheader(request.response, "Connection" => "close")

    # do we need this try-catch-finally block to run @async?
    try
        handle(h, stream)
        closeread(stream)
        closewrite(stream)
    catch e
        @error "error handling request" exception=(e, stacktrace(catch_backtrace()))
        if isopen(stream) && !iswritable(stream)
            stream.message.response.status = 500
            startwrite(stream)
            write(stream, sprint(showerror, e))
        end
        last = true
    finally
        last && close(t.c.io)
    end
    return
end

function check_readtimeout(c, readtimeout, wait_for_timeout)
    @async while wait_for_timeout[]
        if inactiveseconds(c) > readtimeout
            @warn "Connection Timeout: $c"
            try
                writeheaders(c.io, Response(408, ["Connection" => "close"]))
            finally
                close(c)
            end
            break
        end
        sleep(8 + rand() * 4)
    end
    return
end

function handle(h::Handler, c::Connection,
    reuse_limit::Int=0, readtimeout::Int=0)
    wait_for_timeout = Ref{Bool}(true)
    readtimeout > 0 && check_readtimeout(c, readtimeout, wait_for_timeout)
    try
        count = 0
        while isopen(c)
            handle(h, Transaction(c), count == reuse_limit)
            count += 1
        end
    finally
        wait_for_timeout[] = false
    end
    return
end

struct Server2{S, I}
    ssl::S
    server::I
    hostname::String
    hostport::String
end
Base.isopen(s::Server2) = isopen(s.server)
Sockets.accept(s::Server2{Nothing, S}) where {S} = Sockets.accept(s.server)
function getsslcontext(tcp, sslconfig)
    ssl = SSLContext()
    setup!(ssl, sslconfig)
    associate!(ssl, tcp)
    handshake!(ssl)
    return ssl
end
Sockets.accept(s::Server2) = getsslcontext(accept(s.server), s.ssl)
Base.close(s::Server2) = close(s.server)

function listenloop(h::Handler, server,
    tcpisvalid=x->true, connectioncounter=Ref(0),
    reuse_limit::Int=1, readtimeout::Int=0, verbose::Bool=false)
    count = 1
    while isopen(server)
        try
            io = accept(server)
            io === nothing && continue
            if !tcpisvalid(io)
                verbose && @info "Accept-Reject:  $io"
                close(io)
                continue
            end
            connectioncounter[] += 1
            conn = Connection(server.hostname, server.hostport, 0, 0, true, io)
            @async begin
                try
                    verbose && @info "Accept ($count):  $conn"
                    handle(h, conn)
                    verbose && @info "Closed ($count):  $conn"
                catch e
                    @error exception=(e, stacktrace(catch_backtrace()))
                finally
                    connectioncounter[] -= 1
                    close(io)
                    verbose && @info "Closed ($count):  $conn"
                end
            end
        catch e
            if e isa InterruptException
                @warn "Interrupted: listen($server)"
                close(server)
                break
            end
            @error exception=(e, stacktrace(catch_backtrace()))
        end
        count += 1
    end
    return
end

getinet(host::String, port::Integer) = Sockets.InetAddr(parse(IPAddr, host), port)
getinet(host::IPAddr, port::Integer) = Sockets.InetAddr(host, port)

function listen(h::Handler, host::Union{IPAddr, String}, port::Integer;
    tcpref::Union{Ref, Nothing}=nothing,
    reuseaddr::Bool=false,
    sslconfig::Union{MbedTLS.SSLConfig, Nothing}=nothing,
    tcpisvalid::Union{Function, Nothing}=nothing,
    ratelimit::Union{Rational{Int}, Nothing}=nothing,
    connectioncounter::Ref{Int}=Ref(0),
    reuse_limit::Int=1, readtimeout::Int=0, verbose::Bool=false)

    inet = getinet(host, port)
    if tcpref !== nothing
        tcpserver = tcpref[]
    elseif reuseaddr
        tcpserver = Sockets.TCPServer(; delay=false)
        if Sys.islinux() || Sys.isapple()
            rc = ccall(:jl_tcp_reuseport, Int32, (Ptr{Cvoid},), tcpserver.handle)
            Sockets.bind(tcpserver, inet.host, inet.port; reuseaddr=true)
        else
            @warn "reuseaddr=true may not be supported on this platform: $(Sys.KERNEL)"
            Sockets.bind(tcpserver, inet.host, inet.port; reuseaddr=true)
        end
        Sockets.listen(tcpserver)
    else
        tcpserver = Sockets.listen(inet)
    end
    verbose && println("Listening on: $host:$port")

    if tcpisvalid === nothing
        tcpisvalid = ratelimit === nothing ? x->true : x->check_rate_limit(x, ratelimit)
    end

    return listenloop(h, Server2(sslconfig, tcpserver, string(host), string(port)), tcpisvalid,
        connectioncounter, reuse_limit, readtimeout, verbose)
end

function listen(f::Function, host, port::Integer; kw...)
    req = applicable(f, Request())
    strm = applicable(f, Stream(Request(), IOBuffer()))
    if strm && !req
        h = StreamHandlerFunction(f)
    elseif req
        h = RequestHandlerFunction(f)
    else
        throw(ArgumentError("$f function doesn't take an Request or HTTP.Stream argument"))
    end
    return listen(h, host, port; kw...)
end

function serve(host, port; handler=req->HTTP.Response(200, "Hello World!"),
    ssl::Bool=false, require_ssl_verification::Bool=true, kw...)
    Base.depwarn("", nothing)
    sslconfig = ssl ? MbedTLS.SSLConfig(require_ssl_verification) : nothing
    return listen(handler, host, port; sslconfig=sslconfig, kw...)
end

end # module