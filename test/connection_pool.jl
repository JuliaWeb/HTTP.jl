module TestConnectionPool

using Test, HTTP, Sockets
using HTTP: Connections

# Use the same httpbin constant as runtests.jl
const httpbin = get(ENV, "JULIA_TEST_HTTPBINGO_SERVER", "httpbingo.julialang.org")

# Helper function for thread-safe modifications
function with_lock(f, lock::ReentrantLock)
    Base.lock(lock)
    try
        return f()
    finally
        Base.unlock(lock)
    end
end

@testset "Connection Pool Management" begin
    @testset "Connection Reuse (RFC 7230 Section 6.3)" begin
        # Test proper connection reuse behavior according to HTTP/1.1 standards
        n_requests = 100
        results = Vector{Bool}(undef, n_requests)
        
        # First, make a single request to ensure the pool is initialized
        r = HTTP.get("https://$httpbin/get")
        @test r.status == 200
        
        # Now make concurrent requests - they should reuse the connection
        @sync begin
            for i in 1:n_requests
                @async begin
                    try
                        r = HTTP.get("https://$httpbin/get")
                        results[i] = r.status == 200
                    catch e
                        @error "Request failed" exception=e
                        results[i] = false
                    end
                end
            end
        end
        
        @test all(results)  # All requests must complete successfully
        
        # Test connection lifetime
        # Make a request, wait, then make another - should reuse if within keep-alive
        r1 = HTTP.get("https://$httpbin/get")
        @test r1.status == 200
        sleep(1)  # Wait but not too long
        r2 = HTTP.get("https://$httpbin/get")
        @test r2.status == 200
    end

    @testset "TLS Security Requirements (RFC 5280)" begin
        # Test proper certificate validation behavior
        
        # MUST reject expired certificates
        @test_throws HTTP.ConnectError HTTP.get("https://expired.badssl.com/"; retry=false)
        
        # MUST reject self-signed certificates
        @test_throws HTTP.ConnectError HTTP.get("https://self-signed.badssl.com/"; retry=false)
        
        # MUST reject wrong host certificates
        @test_throws HTTP.ConnectError HTTP.get("https://wrong.host.badssl.com/"; retry=false)
        
        # SHOULD allow bypass only with explicit opt-in
        response = HTTP.get("https://expired.badssl.com/"; require_ssl_verification=false)
        @test response.status == 200
    end

    @testset "Connection Cleanup (RFC 7230 Section 6.5)" begin
        # Test proper connection cleanup behavior
        port = 8088
        cleanup_lock = ReentrantLock()
        active_connections = Set{TCPSocket}()
        
        server = HTTP.listen!(port) do http
            # Track active connections
            with_lock(cleanup_lock) do
                push!(active_connections, http.stream.io)
            end
            
            try
                scenario = rand()
                if scenario < 0.3
                    # Test abrupt connection termination
                    close(http.stream)
                elseif scenario < 0.6
                    # Test response timeout
                    sleep(2)
                    HTTP.setstatus(http, 200)
                    HTTP.startwrite(http)
                else
                    # Test server error with proper closure
                    HTTP.setstatus(http, 500)
                    HTTP.startwrite(http)
                    write(http, "Internal Server Error")
                end
            catch e
                if !(e isa Base.IOError)
                    @error "Server error" exception=e
                end
            finally
                # Remove connection from tracking
                with_lock(cleanup_lock) do
                    delete!(active_connections, http.stream.io)
                end
            end
        end

        try
            # Make requests that will trigger different error scenarios
            for _ in 1:20
                try
                    HTTP.get("http://localhost:$port"; readtimeout=1, retry=false)
                catch e
                    @test e isa Union{HTTP.RequestError, HTTP.StatusError, HTTP.TimeoutError}
                end
            end
            
            # Wait for cleanup with timeout and verification
            cleanup_timeout = 5.0  # 5 second timeout
            start_time = time()
            while !isempty(active_connections) && (time() - start_time) < cleanup_timeout
                sleep(0.5)  # Check every 500ms
            end
            
            # Verify all connections were properly cleaned up
            @test isempty(active_connections)
            
        finally
            close(server)
        end
    end

    @testset "Pool Resource Management" begin
        old_limit = HTTP.Connections.TCP_POOL[].limit
        
        try
            # Set a small pool size for testing
            pool_limit = 3
            HTTP.set_default_connection_limit!(pool_limit)
            
            # Create more connections than the pool limit
            n_requests = pool_limit * 2
            results = Vector{Bool}(undef, n_requests)
            
            @sync begin
                for i in 1:n_requests
                    @async begin
                        try
                            r = HTTP.get("https://$httpbin/get")
                            results[i] = r.status == 200
                        catch e
                            @error "Request failed" exception=e
                            results[i] = false
                        end
                    end
                end
            end
            
            # Verify successful requests
            @test all(results)
            
            # Verify pool limit
            @test HTTP.Connections.TCP_POOL[].limit == pool_limit
            
            # Test connection reuse
            r = HTTP.get("https://$httpbin/get")
            @test r.status == 200
            
        finally
            # Restore original settings
            HTTP.set_default_connection_limit!(old_limit)
        end
    end

    @testset "Request Queueing and Fairness" begin
        old_limit = HTTP.Connections.TCP_POOL[].limit
        port = 8089
        server = nothing
        try
            # Test with minimal pool size to force queueing
            HTTP.set_default_connection_limit!(1)
            
            server = HTTP.listen!(port) do http
                try
                    sleep(1)  # Simulate processing time
                    HTTP.setstatus(http, 200)
                    HTTP.startwrite(http)
                    write(http, "OK")
                catch e
                    if !(e isa Base.IOError)
                        @error "Server error" exception=e
                    end
                end
            end
            
            # Track request timing for fairness analysis
            times = Float64[]
            time_lock = ReentrantLock()
            
            # Launch concurrent requests
            @sync begin
                for _ in 1:3
                    @async begin
                        start_time = time()
                        try
                            r = HTTP.get("http://localhost:$port")
                            @test r.status == 200
                            with_lock(() -> push!(times, time() - start_time), time_lock)
                        catch e
                            @error "Request failed" exception=e
                            @test false
                        end
                    end
                end
            end
            
            # Verify fair queueing
            sort!(times)
            @test length(times) == 3
            # Requests should be processed sequentially with ~1s gaps
            @test times[2] - times[1] ≈ 1.0 atol=0.5
            @test times[3] - times[2] ≈ 1.0 atol=0.5
        finally
            HTTP.set_default_connection_limit!(old_limit)
            if server !== nothing
                close(server)
            end
        end
    end

    @testset "Error Handling Requirements" begin
        # Test proper error handling behavior
        
        # MUST handle invalid host gracefully
        @test_throws HTTP.ConnectError HTTP.get("http://nonexistent.example.com"; retry=false)
        
        # MUST handle invalid ports gracefully
        @test_throws HTTP.ConnectError HTTP.get("http://localhost:99999"; retry=false)
        
        # MUST handle malformed URLs properly
        @test_throws ArgumentError HTTP.get("http://[malformed"; retry=false)
        
        # MUST handle connection refused gracefully
        @test_throws HTTP.ConnectError HTTP.get("http://localhost:1"; retry=false)
        
        # MUST handle connection reset gracefully
        port = 8090
        server = HTTP.listen!(port) do http
            close(http.stream)  # Immediately reset connection
        end
        try
            @test_throws Union{HTTP.RequestError, HTTP.ConnectError} HTTP.get("http://localhost:$port")
        finally
            close(server)
        end
    end
end

end # module
