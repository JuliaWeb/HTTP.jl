using JSON
using HTTP.IOExtras

configs = [
    [],
    [:reuse_limit => 200],
    [:reuse_limit => 100],
    [:reuse_limit => 10]
]

@testset "async $count, $num, $config, $http" for count in 1:3,
                                            num in [10, 100, 1000, 2000],
                                            config in configs,
                                            http in ["http", "https"]

println("running async $count, 1:$num, $config, $http")



    result = []
    @sync begin
        for i = 1:min(num,100)
            @async begin
                r = HTTP.RequestStack.request("GET",
                 "$http://httpbin.org/headers", ["i" => i]; config...)
                r = JSON.parse(String(r.body))
                push!(result, r["headers"]["I"] => string(i))
            end
        end
    end
    for (a,b) in result
        @test a == b
    end

    HTTP.ConnectionPool.showpool(STDOUT)
    HTTP.ConnectionPool.closeall()

    result = []

    @sync begin
        for i = 1:min(num,100)
            @async begin
                r = HTTP.RequestStack.request("GET",
                     "$http://httpbin.org/stream/$i"; config...)
                r = String(r.body)
                r = split(strip(r), "\n")
                push!(result, length(r) => i)
            end
        end
    end

    for (a,b) in result
        @test a == b
    end

    HTTP.ConnectionPool.showpool(STDOUT)
    HTTP.ConnectionPool.closeall()

    result = []

    asyncmap(i->begin
        n = i % 20 + 1
        str = ""
        r = HTTP.open("GET", "$http://httpbin.org/stream/$n";
                      retries=5, config...) do s
            str = String(read(s))
        end
        l = split(strip(str), "\n")
        #println("GOT $i $n")

        push!(result, length(l) => n)

    end, 1:num, ntasks=20)

    for (a,b) in result
        @test a == b
    end

    result = []

    @sync begin
        for i = 1:num
            n = i % 20 + 1
            @async begin try
                r = nothing
                str = nothing
                url = "$http://httpbin.org/stream/$n"
                if rand(Bool)
                    if rand(Bool)
                        for attempt in 1:4
                            try
                                #println("GET $i $n BufferStream $attempt")
                                s = BufferStream()
                                r = HTTP.RequestStack.request(
                                    "GET", url; response_stream=s, config...)
                                @assert r.status == 200
                                close(s)
                                str = String(read(s))
                                break
                            catch e
#                                st = catch_stacktrace()
                                if attempt == 10 ||
                                   !HTTP.RetryRequest.isrecoverable(e)
                                    rethrow(e)
                                end
                                buf = IOBuffer()
                                println(buf, "$i retry $e $attempt...")
                                #show(buf, "text/plain", st)
                                write(STDOUT, take!(buf))
                                sleep(0.1)
                            end
                        end
                    else
                        #println("GET $i $n Plain")
                        r = HTTP.RequestStack.request("GET", url; config...)
                        @assert r.status == 200
                        str = String(r.body)
                    end
                else
                    #println("GET $i $n open()")
                    r = HTTP.open("GET", url; config...) do http
                        str = String(read(http))
                    end
                    @assert r.status == 200
                end

                l = split(strip(str), "\n")
                #println("GOT $i $n $(length(l))")
                if length(l) != n
                    @show r
                    @show str
                end
                push!(result, length(l) => n)
            catch e
                push!(result, e => n)
                buf = IOBuffer()
                write(buf, "==========\nAsync exception:\n==========\n$e\n")
                show(buf, "text/plain", catch_stacktrace())
                write(buf, "==========\n\n")
                write(STDOUT, take!(buf))
            end end
        end
    end

    for (a,b) in result
        @test a == b
    end

    HTTP.ConnectionPool.showpool(STDOUT)
    HTTP.ConnectionPool.closeall()

end # testset
