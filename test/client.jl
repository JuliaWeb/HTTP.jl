@testset "Client.jl" begin
    @testset "GET, HEAD, POST, PUT, DELETE, PATCH: $scheme" for scheme in ["http", "https"]
        @test isok(HTTP.get("$scheme://$httpbin/ip"))
        @test isok(HTTP.head("$scheme://$httpbin/ip"))
        @test HTTP.post("$scheme://$httpbin/patch"; status_exception=false).status == 405
        @test isok(HTTP.post("$scheme://$httpbin/post"; redirect_method=:same))
        @test isok(HTTP.put("$scheme://$httpbin/put"; redirect_method=:same))
        @test isok(HTTP.delete("$scheme://$httpbin/delete"; redirect_method=:same))
        @test isok(HTTP.patch("$scheme://$httpbin/patch"; redirect_method=:same))
    end

    @testset "decompress" begin
        r = HTTP.get("https://$httpbin/gzip")
        @test isok(r)
        @test isascii(String(r.body))
        r = HTTP.get("https://$httpbin/gzip"; decompress=false)
        @test isok(r)
        @test !isascii(String(r.body))
        r = HTTP.get("https://$httpbin/gzip"; decompress=true)
        @test isok(r)
        @test isascii(String(r.body))
    end

    @testset "ASync Client Requests" begin
        @test isok(fetch(Threads.@spawn HTTP.get("https://$httpbin/ip")))
        @test isok(HTTP.get("https://$httpbin/encoding/utf8"))
    end

    @testset "Query to URI" begin
        r = HTTP.get(URI(HTTP.URI("https://$httpbin/response-headers"); query=Dict("hey"=>"dude")))
        h = Dict(r.headers)
        @test (haskey(h, "Hey") ? h["Hey"] == "dude" : h["hey"] == "dude")
    end

    @testset "Cookie Requests" begin
        empty!(HTTP.COOKIEJAR)
        url = "https://$httpbin/cookies"
        r = HTTP.get(url, cookies=true)
        @test String(r.body) == "{}"
        cookies = HTTP.Cookies.getcookies!(HTTP.COOKIEJAR, "https", httpbin, "/cookies")
        @test isempty(cookies)

        url = "https://$httpbin/cookies/set?hey=sailor&foo=bar"
        r = HTTP.get(url, cookies=true)
        @test isok(r)
        @test String(r.body) == "{\"foo\":\"bar\",\"hey\":\"sailor\"}"
        cookies = HTTP.Cookies.getcookies!(HTTP.COOKIEJAR, "https", httpbin, "/cookies")
        @test length(cookies) == 2

        url = "https://$httpbin/cookies/delete?hey"
        r = HTTP.get(url)
        @test isok(r)
        @test String(r.body) == "{\"foo\":\"bar\"}"
        cookies = HTTP.Cookies.getcookies!(HTTP.COOKIEJAR, "https", httpbin, "/cookies")
        @test length(cookies) == 1
    end

    @testset "Client Streaming Test" begin
        r = HTTP.post("https://$httpbin/anything"; body="hey")
        @test isok(r)
        @test contains(String(r.body), "\"data\":\"hey\"")

        r = HTTP.get("https://$httpbin/stream/100")
        @test isok(r)
        x = map(String, split(String(r.body), '\n'; keepempty=false))
        @test length(x) == 100

        io = IOBuffer()
        r = HTTP.get("https://$httpbin/stream/100"; response_body=io)
        @test isok(r)
        x2 = map(String, split(String(take!(io)), '\n'; keepempty=false))
        @test x == x2

        # pass pre-allocated buffer
        body = zeros(UInt8, 100)
        r = HTTP.get("https://$httpbin/bytes/100"; response_body=body)
        @test length(body) == 100
        @test any(x -> x != 0, body)

        # if provided buffer is too small, we won't grow it for user
        body = zeros(UInt8, 10)
        @test_throws BoundsError HTTP.get("https://$httpbin/bytes/100"; response_body=body)

        # also won't shrink it if buffer provided is larger than response body
        body = zeros(UInt8, 10)
        r = HTTP.get("https://$httpbin/bytes/5"; response_body=body)
        @test length(body) == 10
        @test all(x -> x == 0, body[6:end])

        # but if you wrap it in a writable IOBuffer, we will grow it
        io = IOBuffer(body; write=true)
        r = HTTP.get("https://$httpbin/bytes/100"; response_body=io)
        @test length(take!(io)) == 100

        # and you can reuse it
        seekstart(io)
        r = HTTP.get("https://$httpbin/bytes/100"; response_body=io)
        @test length(take!(io)) == 100

        # we respect ptr and size
        body = zeros(UInt8, 100)
        io = IOBuffer(body; write=true, append=true) # size=100, ptr=1
        r = HTTP.get("https://$httpbin/bytes/100"; response_body=io)
        @test length(take!(io)) == 200

        body = zeros(UInt8, 100)
        io = IOBuffer(body, write=true, append=false)
        write(io, body) # size=100, ptr=101
        r = HTTP.get("https://$httpbin/bytes/100"; response_body=io)
        @test length(take!(io)) == 200

        # status error response body handling
        r = HTTP.post("https://$httpbin/status/404"; status_exception=false)
    end

    @testset "Client Body Posting - Vector{UTF8}, String, IOStream, IOBuffer, BufferStream, Dict, NamedTuple" begin
        @test isok(HTTP.post("https://$httpbin/post"; body="hey"))
        @test isok(HTTP.post("https://$httpbin/post"; body=UInt8['h','e','y']))
        io = IOBuffer("hey"); seekstart(io)
        @test isok(HTTP.post("https://$httpbin/post"; body=io))
        mktemp() do path, io
            write(io, "hey"); seekstart(io)
            @test isok(HTTP.post("https://$httpbin/post"; body=io))
        end
        f = Base.BufferStream()
        write(f, "hey")
        close(f)
        @test isok(HTTP.post("https://$httpbin/post"; body=f))
        resp = HTTP.post("https://$httpbin/post"; body=Dict("name" => "value"))
        @test isok(resp)
        # x = JSONBase.materialize(resp.body)
        # @test x["form"] == Dict("name" => ["value"])
        resp = HTTP.post("https://$httpbin/post"; body=(name="value with spaces",))
        @test isok(resp)
        # x = JSONBase.materialize(resp.body)
        # @test x["form"] == Dict("name" => ["value with spaces"])
        resp = HTTP.post("https://$httpbin/post"; body=["hey", " there ", "sailor"])
        @test isok(resp)
        @test occursin("\"data\":\"hey there sailor\"", String(resp.body))
    end

    @testset "ASync Client Request Body" begin
        f = Base.BufferStream()
        write(f, "hey")
        t = Threads.@spawn HTTP.post("https://$httpbin/post"; body=f)
        #fetch(f) # fetch for the async call to write it's first data
        write(f, " there ") # as we write to f, it triggers another chunk to be sent in our async request
        write(f, "sailor")
        close(f) # setting eof on f causes the async request to send a final chunk and return the response
        r = fetch(t)
        @test isok(r)
        @test contains(String(r.body), "\"data\":\"hey there sailor\"")
    end

    @testset "Client Redirect Following - $read_method" for read_method in ["GET", "HEAD"]
        @test isok(HTTP.request(read_method, "https://$httpbin/redirect/1"))
        @test HTTP.request(read_method, "https://$httpbin/redirect/1", redirect=false, status_exception=false).status == 302
        @test HTTP.request(read_method, "https://$httpbin/redirect/6", status_exception=false).status == 302 #over max number of redirects
        @test isok(HTTP.request(read_method, "https://$httpbin/relative-redirect/1"))
        @test isok(HTTP.request(read_method, "https://$httpbin/absolute-redirect/1"))
        @test isok(HTTP.request(read_method, "https://$httpbin/redirect-to?url=http%3A%2F%2Fgoogle.com"))
    end

    @testset "Client Basic Auth" begin
        @test isok(HTTP.get("https://user:pwd@$httpbin/basic-auth/user/pwd"))
        @test isok(HTTP.get("https://user:pwd@$httpbin/hidden-basic-auth/user/pwd"))
        @test isok(HTTP.get("https://test:%40test@$httpbin/basic-auth/test/%40test"))
        @test isok(HTTP.get("https://$httpbin/basic-auth/user/pwd"; username="user", password="pwd"))
    end

    @testset "Misc" begin
        @test isok(HTTP.post("https://$httpbin/post"; body="√"))
        r = HTTP.request("GET", "https://$httpbin/ip")
        @test isok(r)

        uri = HTTP.URI("https://$httpbin/ip")
        r = HTTP.request("GET", uri)
        @test isok(r)
        r = HTTP.get(uri)
        @test isok(r)

        # ensure we can use AbstractString for requests
        r = HTTP.get(SubString("https://$httpbin/ip",1))
        @test isok(r)

        # Ensure HEAD requests stay the same through redirects by default
        r = HTTP.head("https://$httpbin/redirect/1")
        @test r.request.method == "HEAD"
        @test iszero(length(r.body))
        # But if explicitly requested, GET can be used instead
        r = HTTP.head("https://$httpbin/redirect/1"; redirect_method="GET")
        @test r.request.method == "GET"
        @test length(r.body) > 0
    end

    @testset "Header insertion" begin
        server = HTTP.serve!(req -> begin
            accept_count = length(HTTP.headers(req, "accept"))
            host_count = length(HTTP.headers(req, "host"))
            return HTTP.Response(200, "$accept_count,$host_count")
        end; listenany=true)
        try
            port = HTTP.port(server)
            resp = HTTP.get("http://127.0.0.1:$port"; headers=["Accept" => "*/*", "Host" => "example.com"])
            @test String(resp.body) == "1,1"
            resp = HTTP.get("http://127.0.0.1:$port")
            @test String(resp.body) == "1,1"
        finally
            close(server)
        end
    end

    @testset "readtimeout" begin
    @test_throws HTTP.TimeoutError HTTP.get("http://$httpbin/delay/5"; readtimeout=1, max_retries=0)
        @test isok(HTTP.get("http://$httpbin/delay/1"; readtimeout=2, max_retries=0))
    end

    @testset "Retry semantics" begin
        attempts = Ref(0)
        failures = Ref(1)
        attempt_lock = ReentrantLock()
        next_attempt() = Base.@lock attempt_lock begin
            attempts[] += 1
            return attempts[]
        end
        reset_attempts!(nfail) = Base.@lock attempt_lock begin
            attempts[] = 0
            failures[] = nfail
            return
        end

        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
            n = next_attempt()
            if n <= failures[]
                return HTTP.Response(503, "fail")
            end
            return HTTP.Response(200, "ok")
        end
        port = HTTP.port(server)
        try
            reset_attempts!(1)
            resp = HTTP.get("http://127.0.0.1:$port/"; retries=1, retry_delays=[0.0])
            @test resp.status == 200
            @test resp.metrics.nretries == 1
            @test attempts[] == 2

            reset_attempts!(1)
            err = nothing
            try
                HTTP.post("http://127.0.0.1:$port/"; body="x", retries=1, retry_delays=[0.0])
            catch e
                err = e
            end
            @test err isa HTTP.StatusError
            @test err.response.metrics.nretries == 0
            @test attempts[] == 1

            reset_attempts!(1)
            resp = HTTP.post("http://127.0.0.1:$port/"; body="x", retries=1,
                retry_non_idempotent=true, retry_delays=[0.0])
            @test resp.status == 200
            @test resp.metrics.nretries == 1
            @test attempts[] == 2

            reset_attempts!(1)
            resp = HTTP.post("http://127.0.0.1:$port/"; body="x", retries=1,
                retry_check=(s, ex, req, resp, resp_body) -> true, retry_delays=[0.0])
            @test resp.status == 200
            @test resp.metrics.nretries == 1
            @test attempts[] == 2

            reset_attempts!(2)
            err = nothing
            try
                HTTP.get("http://127.0.0.1:$port/"; retries=3, retry_delays=[0.0])
            catch e
                err = e
            end
            @test err isa HTTP.StatusError
            @test attempts[] == 2

            reset_attempts!(1)
            resp = HTTP.get("http://127.0.0.1:$port/"; retries=1, retry_partition="test")
            @test resp.status == 200
            @test resp.metrics.nretries == 1
            @test attempts[] == 2
        finally
            close(server)
        end
    end

    @testset "Request metrics" begin
        server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
            body = read(http)
            HTTP.setstatus(http, 200)
            HTTP.startwrite(http)
            write(http, body)
        end
        try
            port = HTTP.port(server)
            resp = HTTP.post("http://127.0.0.1:$port/"; body="hello")
            @test resp.metrics.request_body_length == 5
            @test resp.metrics.response_body_length == 5

            resp = HTTP.post("http://127.0.0.1:$port/"; body=IOBuffer("chunked"))
            @test resp.metrics.request_body_length == 7
            @test resp.metrics.response_body_length == 7
        finally
            close(server)
        end
    end

    @testset "Request Options Parity" begin
        headers = ["X-Test" => "1"]
        HTTP.get("https://$httpbin/headers"; headers=headers, copyheaders=true)
        @test headers == ["X-Test" => "1"]

        headers2 = ["X-Test" => "1"]
        HTTP.get("https://$httpbin/headers"; headers=headers2, copyheaders=false)
        @test any(h -> lowercase(String(h.first)) == "accept", headers2)
        @test any(h -> lowercase(String(h.first)) == "x-test", headers2)

        resp = HTTP.get("https://user:pwd@$httpbin/headers"; basicauth=false)
        @test HTTP.getheader(resp.request.headers, "authorization") === nothing

        resp = HTTP.get("https://user:pwd@$httpbin/headers"; basicauth=true)
        auth = HTTP.getheader(resp.request.headers, "authorization")
        @test auth !== nothing && startswith(auth, "Basic ")

        resp = HTTP.post("https://$httpbin/anything"; body="hello", detect_content_type=true)
        @test HTTP.getheader(resp.request.headers, "content-type") == "text/plain; charset=utf-8"

        orig_agent = HTTP.USER_AGENT[]
        try
            HTTP.setuseragent!(nothing)
            resp = HTTP.get("https://$httpbin/headers")
            @test HTTP.getheader(resp.request.headers, "user-agent") === nothing
        finally
            HTTP.setuseragent!(orig_agent)
        end

        pool = HTTP.Pool(1)
        @test isempty(pool.clients.clients)
        HTTP.get("https://$httpbin/ip"; pool=pool)
        @test !isempty(pool.clients.clients)
    end

    @testset "observelayers" begin
        server = HTTP.serve!(req -> begin
            if req.target == "/redirect"
                return HTTP.Response(302, ["Location" => "/ok"], nothing)
            end
            return HTTP.Response(200, "ok")
        end; listenany=true)
        try
            port = HTTP.port(server)
            resp = HTTP.get("http://127.0.0.1:$port/redirect"; observelayers=true, retries=0)
            ctx = resp.request.context
            @test ctx[:messagelayer_count] >= 1
            @test ctx[:redirectlayer_count] >= 1
            @test ctx[:retrylayer_count] >= 1
            @test ctx[:connectionlayer_count] >= 1
            @test ctx[:streamlayer_count] >= 1
            @test ctx[:total_request_duration_ms] > 0
        finally
            close(server)
        end
    end

    @testset "IO request body streaming" begin
        mutable struct ChunkedTestIO <: IO
            chunks::Vector{Vector{UInt8}}
            readbytes_calls::Int
            readavailable_calls::Int
        end
        ChunkedTestIO(chunks) = ChunkedTestIO(chunks, 0, 0)
        Base.eof(io::ChunkedTestIO) = isempty(io.chunks)
        function Base.readbytes!(io::ChunkedTestIO, buf::Vector{UInt8}, n::Integer)
            io.readbytes_calls += 1
            isempty(io.chunks) && return 0
            chunk = popfirst!(io.chunks)
            ncopy = min(n, length(chunk))
            copyto!(buf, 1, chunk, 1, ncopy)
            return ncopy
        end
        function Base.readavailable(io::ChunkedTestIO)
            io.readavailable_calls += 1
            error("readavailable should not be used for chunked IO")
        end

        server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
            body = String(read(http))
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "text/plain")
            HTTP.startwrite(http)
            write(http, body)
        end
        try
            port = HTTP.port(server)
            io = ChunkedTestIO([Vector{UInt8}("hello"), Vector{UInt8}(" "), Vector{UInt8}("world")])
            resp = HTTP.post("http://127.0.0.1:$port/"; body=io)
            @test String(resp.body) == "hello world"
            @test io.readbytes_calls == 3
            @test io.readavailable_calls == 0
        finally
            close(server)
        end
    end

    @testset "closed IOStream body errors" begin
        path = tempname()
        io = open(path, "w")
        close(io)
        @test_throws ArgumentError HTTP.request("POST", "http://example.com"; body=io, retry=false, status_exception=false)
    end

    @testset "Iterable request body streaming" begin
        mutable struct ChunkedIterable
            chunks::Vector{Vector{UInt8}}
            iter_calls::Int
        end
        ChunkedIterable(chunks) = ChunkedIterable(chunks, 0)
        function Base.iterate(it::ChunkedIterable, state::Int=1)
            state > length(it.chunks) && return nothing
            it.iter_calls += 1
            return (it.chunks[state], state + 1)
        end

        server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
            body = String(read(http))
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "text/plain")
            HTTP.startwrite(http)
            write(http, body)
        end
        try
            port = HTTP.port(server)
            chunks = ChunkedIterable([Vector{UInt8}("hello"), Vector{UInt8}(" "), Vector{UInt8}("world")])
            resp = HTTP.post("http://127.0.0.1:$port/"; body=chunks)
            @test String(resp.body) == "hello world"
            @test chunks.iter_calls == 3
        finally
            close(server)
        end
    end

    @testset "stream helpers" begin
        server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
            body = String(read(http))
            if http.request.method == "POST"
                HTTP.setstatus(http, 200)
                HTTP.startwrite(http)
                write(http, body)
            else
                HTTP.setstatus(http, 500)
                HTTP.setheader(http, "Connection" => "close")
                HTTP.startwrite(http)
                write(http, "error")
            end
        end
        try
            port = HTTP.port(server)
            resp = HTTP.open("GET", "http://127.0.0.1:$port"; status_exception=false) do io
                r = HTTP.startread(io)
                @test r.status == 500
                @test HTTP.isaborted(io)
                buf = IOBuffer()
                n = HTTP.readall!(io, buf)
                @test n > 0
                @test String(take!(buf)) == "error"
            end
            @test resp.status == 500

            resp = HTTP.open("POST", "http://127.0.0.1:$port") do io
                write(io, "hello")
                HTTP.closebody(io)
                r = HTTP.startread(io)
                @test r.status == 200
                @test String(read(io)) == "hello"
            end
            @test resp.status == 200
        finally
            close(server)
        end
    end

    @testset "HTTP.open streaming" begin
        resp = HTTP.open("GET", "https://$httpbin/stream/5") do io
            r = HTTP.startread(io)
            @test r.status == 200
            data = String(read(io))
            @test length(split(chomp(data), '\n')) == 5
        end
        @test resp.status == 200

        resp = HTTP.open("POST", "https://$httpbin/anything") do io
            write(io, "hello")
            HTTP.closewrite(io)
            r = HTTP.startread(io)
            data = String(read(io))
            @test occursin("\"data\":\"hello\"", data)
        end
        @test resp.status == 200
    end

    @testset "HTTP/2 stream manager smoke" begin
        cs = HTTP.ClientSettings("https", "example.com", UInt32(443); http2_stream_manager=true)
        client = HTTP.Client(cs)
        @test client.http2_stream_manager != C_NULL
        finalize(client)
    end

    @testset "HTTP/2 stream manager options" begin
        cs = HTTP.ClientSettings("https", "example.com", UInt32(443);
            http2_stream_manager=true,
            http2_close_connection_on_server_error=true,
            http2_connection_ping_period_ms=1234,
            http2_connection_ping_timeout_ms=2345,
            http2_ideal_concurrent_streams_per_connection=7,
            http2_max_concurrent_streams_per_connection=9,
        )
        client = HTTP.Client(cs)
        opts = client.http2_stream_manager_opts
        @test opts !== nothing
        @test opts.close_connection_on_server_error == true
        @test opts.connection_ping_period_ms == Csize_t(1234)
        @test opts.connection_ping_timeout_ms == Csize_t(2345)
        @test opts.ideal_concurrent_streams_per_connection == Csize_t(7)
        @test opts.max_concurrent_streams_per_connection == Csize_t(9)
        finalize(client)
    end

    @testset "HTTP/2 initial settings options" begin
        settings = [
            HTTP.AWS_HTTP2_SETTINGS_MAX_CONCURRENT_STREAMS => 10,
            HTTP.AWS_HTTP2_SETTINGS_INITIAL_WINDOW_SIZE => 65535,
        ]
        cs = HTTP.ClientSettings("https", "example.com", UInt32(443); http2_initial_settings=settings)
        client = HTTP.Client(cs)
        @test client.http2_initial_settings !== nothing
        @test length(client.http2_initial_settings) == 2
        @test client.conn_manager_opts.num_initial_settings == Csize_t(2)
        @test client.conn_manager_opts.initial_settings_array != C_NULL
        finalize(client)

        cs = HTTP.ClientSettings("https", "example.com", UInt32(443);
            http2_stream_manager=true,
            http2_initial_settings=settings,
        )
        client = HTTP.Client(cs)
        opts = client.http2_stream_manager_opts
        @test opts !== nothing
        @test opts.num_initial_settings == Csize_t(2)
        @test opts.initial_settings_array != C_NULL
        finalize(client)

        @test_throws ArgumentError HTTP.Client(HTTP.ClientSettings("https", "example.com", UInt32(443);
            http2_initial_settings=1,
        ))
    end

    @testset "HTTP manager metrics" begin
        client = HTTP.Client(HTTP.ClientSettings("https", "example.com", UInt32(443)))
        metrics = HTTP.manager_metrics(client)
        @test metrics.available_concurrency >= 0
        @test metrics.pending_concurrency_acquires >= 0
        @test metrics.leased_concurrency >= 0
        finalize(client)

        client = HTTP.Client(HTTP.ClientSettings("https", "example.com", UInt32(443); http2_stream_manager=true))
        metrics = HTTP.manager_metrics(client)
        @test metrics.available_concurrency >= 0
        @test metrics.pending_concurrency_acquires >= 0
        @test metrics.leased_concurrency >= 0
        finalize(client)
    end

    @testset "HTTP connection monitoring stats" begin
        list = Ref{HTTP.aws_array_list}()
        HTTP.aws_array_list_init_dynamic(list, HTTP.default_aws_allocator(), 1, sizeof(HTTP.aws_crt_statistics_http1_channel))
        stat1 = HTTP.aws_crt_statistics_http1_channel(HTTP.AWSCRT_STAT_CAT_HTTP1_CHANNEL, 10, 20, 1, 2)
        HTTP.aws_array_list_push_back(list, Ref(stat1))
        decoded = HTTP._decode_statistics(list)
        @test length(decoded) == 1
        @test decoded[1].category == :http1_channel
        @test decoded[1].pending_outgoing_stream_ms == 10
        @test decoded[1].pending_incoming_stream_ms == 20
        @test decoded[1].current_outgoing_stream_id == 1
        @test decoded[1].current_incoming_stream_id == 2
        HTTP.aws_array_list_clean_up(list)

        list = Ref{HTTP.aws_array_list}()
        HTTP.aws_array_list_init_dynamic(list, HTTP.default_aws_allocator(), 1, sizeof(HTTP.aws_crt_statistics_http2_channel))
        stat2 = HTTP.aws_crt_statistics_http2_channel(HTTP.AWSCRT_STAT_CAT_HTTP2_CHANNEL, 5, 6, true)
        HTTP.aws_array_list_push_back(list, Ref(stat2))
        decoded = HTTP._decode_statistics(list)
        @test length(decoded) == 1
        @test decoded[1].category == :http2_channel
        @test decoded[1].pending_outgoing_stream_ms == 5
        @test decoded[1].pending_incoming_stream_ms == 6
        @test decoded[1].was_inactive == true
        HTTP.aws_array_list_clean_up(list)

        called = Ref(false)
        cb = (nonce, stats) -> (called[] = true)
        client = HTTP.Client(HTTP.ClientSettings("https", "example.com", UInt32(443); monitoring_statistics_observer=cb))
        list = Ref{HTTP.aws_array_list}()
        HTTP.aws_array_list_init_dynamic(list, HTTP.default_aws_allocator(), 1, sizeof(HTTP.aws_crt_statistics_http1_channel))
        stat3 = HTTP.aws_crt_statistics_http1_channel(HTTP.AWSCRT_STAT_CAT_HTTP1_CHANNEL, 1, 1, 1, 1)
        HTTP.aws_array_list_push_back(list, Ref(stat3))
        HTTP.c_on_statistics_observer(Csize_t(0), Base.unsafe_convert(Ptr{HTTP.aws_array_list}, list), pointer_from_objref(client.monitoring_observer))
        @test called[]
        HTTP.aws_array_list_clean_up(list)
        finalize(client)
    end

    @testset "Proxy basic auth strategy" begin
        opts = HTTP.proxy_kwargs("http://user:pass@proxy.local:3128", "http")
        @test opts.proxy_auth == :basic
        @test opts.proxy_username == "user"
        @test opts.proxy_password == "pass"

        cs = HTTP.ClientSettings("https", "example.com", UInt32(443);
            proxy_host="proxy.local",
            proxy_port=UInt32(3128),
            proxy_connection_type=:forward,
            proxy_auth=:basic,
            proxy_username="user",
            proxy_password="pass",
        )
        client = HTTP.Client(cs)
        @test client.proxy_options !== nothing
        @test client.proxy_strategy != C_NULL
        @test client.proxy_options.proxy_strategy == client.proxy_strategy
        finalize(client)

        @test_throws ArgumentError HTTP.Client(HTTP.ClientSettings("https", "example.com", UInt32(443);
            proxy_host="proxy.local",
            proxy_port=UInt32(3128),
            proxy_auth=:basic,
            proxy_username="user",
        ))
    end

    @testset "HTTP/2 control APIs" begin
        resp = HTTP.get("https://$httpbin/ip")
        if resp.version == HTTP.HTTPVersion(2, 0)
            HTTP.open("GET", "https://$httpbin/ip") do io
                r = HTTP.startread(io)
                @test r.status == 200
                rtt = HTTP.http2_ping(io)
                @test rtt isa UInt64
                HTTP.http2_change_settings(io, Pair{Int, Int}[])
                @test length(HTTP.http2_local_settings(io)) == HTTP.AWS_HTTP2_SETTINGS_COUNT
                @test HTTP.http2_get_sent_goaway(io) === nothing
                @test HTTP.http2_get_received_goaway(io) === nothing
            end
        else
            @info "HTTP/2 not available for $httpbin"
        end
    end

    @testset "Public entry point of HTTP.request and friends (e.g. issue #463)" begin
        headers = Dict("User-Agent" => "HTTP.jl")
        query = Dict("hello" => "world")
        body = UInt8[1, 2, 3]
        for uri in ("https://$httpbin/anything", HTTP.URI("https://$httpbin/anything"))
            # HTTP.request
            @test isok(HTTP.request("GET", uri; headers=headers, body=body, query=query))
            @test isok(HTTP.request("GET", uri, headers; body=body, query=query))
            @test isok(HTTP.request("GET", uri, headers, body; query=query))
            # HTTP.get
            @test isok(HTTP.get(uri; headers=headers, body=body, query=query))
            @test isok(HTTP.get(uri, headers; body=body, query=query))
            @test isok(HTTP.get(uri, headers, body; query=query))
            # HTTP.put
            @test isok(HTTP.put(uri; headers=headers, body=body, query=query))
            @test isok(HTTP.put(uri, headers; body=body, query=query))
            @test isok(HTTP.put(uri, headers, body; query=query))
            # HTTP.post
            @test isok(HTTP.post(uri; headers=headers, body=body, query=query))
            @test isok(HTTP.post(uri, headers; body=body, query=query))
            @test isok(HTTP.post(uri, headers, body; query=query))
            # HTTP.patch
            @test isok(HTTP.patch(uri; headers=headers, body=body, query=query))
            @test isok(HTTP.patch(uri, headers; body=body, query=query))
            @test isok(HTTP.patch(uri, headers, body; query=query))
            # HTTP.delete
            @test isok(HTTP.delete(uri; headers=headers, body=body, query=query))
            @test isok(HTTP.delete(uri, headers; body=body, query=query))
            @test isok(HTTP.delete(uri, headers, body; query=query))
        end
    end
end
