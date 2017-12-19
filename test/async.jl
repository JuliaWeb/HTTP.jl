@testset "HTTP.async" begin

using JSON


for http in ("http", "https")
    println("running $http async tests...")

    @sync begin
        for i = 1:100
            @async begin
                r = HTTP.RequestStack.request("GET", "$http://httpbin.org/headers", ["i" => i])
                r = JSON.parse(String(take!(r)))
                @test r["headers"]["I"] == string(i)
            end
        end
    end

    HTTP.ConnectionPool.showpool(STDOUT)
    HTTP.ConnectionPool.closeall()
    

    @sync begin
        for i = 1:100
            @async begin
                r = HTTP.RequestStack.request("GET", "$http://httpbin.org/stream/$i")
                r = String(take!(r))
                r = split(strip(r), "\n")
                @test length(r) == i
            end
        end
    end

    HTTP.ConnectionPool.showpool(STDOUT)
    HTTP.ConnectionPool.closeall()

    asyncmap(i->begin
        n = i % 20 + 1
        for attempt in 1:3
            r = nothing
            try
                println("GET $i $n")
                s = BufferStream()
                r = HTTP.RequestStack.request("GET", "$http://httpbin.org/stream/$n";
                                              retries=5, response_stream=s)
                wait(r)
                r = String(read(s))
                break
            catch e
                if attempt == 3 || !HTTP.RetryRequest.isrecoverable(e)
                    rethrow(e)
                end
            end
        end
        
        r = split(strip(r), "\n")
        println("GOT $i $n")
        @test length(r) == n
        
    end, 1:1000, ntasks=20)


    @sync begin
        for i = 1:1000
            @async begin
                n = i % 20 + 1
                for attempt in 1:3
                    r = nothing
                    try
                        s = BufferStream()
                        println("GET $i $n")
                        r = HTTP.RequestStack.request("GET", "$http://httpbin.org/stream/$n";
                                                      response_stream=s)
                        wait(r)
                        r = String(read(s))
                        break
                    catch e
                        if attempt == 3 || !HTTP.RetryRequest.isrecoverable(e)
                            rethrow(e)
                        end
                    end
                end
                    
                r = split(strip(r), "\n")
                println("GOT $i $n")
                @test length(r) == n
            end
        end
    end


    HTTP.ConnectionPool.showpool(STDOUT)
    HTTP.ConnectionPool.closeall()

end

end # @testset "HTTP.Client"
