module TestPool

using HTTP
import ..httpbin
using Sockets
using Test

function pooledconnections(socket_type)
    pool = HTTP.Connections.getpool(nothing, socket_type)
    conns_per_key = values(pool.keyedvalues)
    [c for conns in conns_per_key for c in conns if isopen(c)]
end

@testset "$schema pool" for (schema, socket_type) in [
        ("http", Sockets.TCPSocket),
        ("https", HTTP.SOCKET_TYPE_TLS[])]
    HTTP.Connections.closeall()
    @test length(pooledconnections(socket_type)) == 0
    try
        function request_ip()
            r = HTTP.get("$schema://$httpbin/ip"; retry=false, redirect = false, status_exception=true)
            String(r.body)
        end

        @testset "Sequential request use the same socket" begin
            request_ip()
            conns = pooledconnections(socket_type)
            @test length(conns) == 1
            conn1io = conns[1].io
            
            request_ip()
            conns = pooledconnections(socket_type)
            @test length(conns) == 1
            @test conn1io === conns[1].io
        end

        @testset "Parallell requests however use parallell connections" begin
            n_asyncgetters = 3
            asyncgetters = [@async request_ip() for _ in 1:n_asyncgetters]
            wait.(asyncgetters)
            
            conns = pooledconnections(socket_type)
            @test length(conns) == n_asyncgetters
        end
    finally
        HTTP.Connections.closeall()
    end
end

function readwrite(src, dst)
    n = 0
    while isopen(dst) && !eof(src)
        buff = readavailable(src)
        if isopen(dst)
            write(dst, buff)
        end
        n += length(buff)
    end
    n
end

@testset "http pool with proxy" begin
    downstreamconnections = Base.IdSet{HTTP.Connections.Connection}()
    upstreamconnections = Base.IdSet{HTTP.Connections.Connection}()
    downstreamcount = 0
    upstreamcount = 0

    # Simple implementation of an http proxy server
    proxy = HTTP.listen!(IPv4(0), 8082; stream = true) do http::HTTP.Stream
        push!(downstreamconnections, http.stream)
        downstreamcount += 1
        
        HTTP.open(http.message.method, http.message.target, http.message.headers;
                  decompress = false, version = http.message.version, retry=false,
                  redirect = false) do targetstream
            push!(upstreamconnections, targetstream.stream)
            upstreamcount += 1
            
            up = @async readwrite(http, targetstream)
            targetresponse = startread(targetstream)

            HTTP.setstatus(http, targetresponse.status)
            for h in targetresponse.headers
                HTTP.setheader(http, h)
            end

            HTTP.startwrite(http)
            readwrite(targetstream, http)

            wait(up)
        end
    end

    try
        function http_request_ip_through_proxy()
            r = HTTP.get("http://$httpbin/ip"; proxy="http://localhost:8082", retry=false, redirect = false, status_exception=true) 
            String(r.body)
        end

        # Make the HTTP request
        http_request_ip_through_proxy()
        @test length(downstreamconnections) == 1
        @test length(upstreamconnections) == 1
        @test downstreamcount == 1
        @test upstreamcount == 1

        # Make another request
        # This should reuse connections from the pool in both the client and the proxy
        http_request_ip_through_proxy()
        
        # Check that additional requests were made, both downstream and upstream
        @test downstreamcount == 2
        @test upstreamcount == 2
        # But the set of unique connections in either direction should remain of size 1
        @test length(downstreamconnections) == 1
        @test length(upstreamconnections) == 1
    finally
        HTTP.Connections.closeall()
        close(proxy)
        wait(proxy)
    end
end

function readwriteclose(src, dst)
    try
        readwrite(src, dst)
    finally
        close(src)
        close(dst)
    end
end

@testset "https pool with proxy" begin
    connectcount = 0

    # Simple implementation of a connect proxy server
    proxy = HTTP.listen!(IPv4(0), 8082; stream = true) do http::HTTP.Stream
        @assert http.message.method == "CONNECT"
        connectcount += 1

        hostport = split(http.message.target, ":")
        targetstream = connect(hostport[1], parse(Int, get(hostport, 2, "443")))

        HTTP.setstatus(http, 200)
        HTTP.startwrite(http)
        up = @async readwriteclose(http.stream.io, targetstream)
        readwriteclose(targetstream, http.stream.io)
        wait(up)
    end

    try
        function https_request_ip_through_proxy()
            r = HTTP.get("https://$httpbin/ip"; proxy="http://localhost:8082", retry=false, status_exception=true)
            String(r.body)
        end
    
        @testset "Only one tunnel should be established with sequential requests" begin
            https_request_ip_through_proxy()
            https_request_ip_through_proxy()
            @test connectcount == 1
        end
        
        @testset "parallell tunnels should be established with parallell requests" begin
            n_asyncgetters = 3
            asyncgetters = [@async https_request_ip_through_proxy() for _ in 1:n_asyncgetters]
            wait.(asyncgetters)
            @test connectcount == n_asyncgetters
        end
    
    finally
        # Close pooled connections explicitly so the proxy handler can finish
        # Connections.closeall never closes anything
        close.(pooledconnections(HTTP.SOCKET_TYPE_TLS[]))

        HTTP.Connections.closeall()
        close(proxy)
        wait(proxy)
    end
end

end # module
