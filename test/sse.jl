module test_sse

using HTTP, Test, CodecZlib

const HOST = "127.0.0.1"

function with_sse_server(f::Function, chunks::Vector; content_type::AbstractString="text/event-stream",
        status::Int=200, headers::Vector{Pair{String,String}}=Pair{String,String}[])
    stream_handler = stream -> begin
        HTTP.setstatus(stream, status)
        HTTP.setheader(stream, "Content-Type" => content_type)
        HTTP.setheader(stream, "Cache-Control" => "no-cache")
        for h in headers
            HTTP.setheader(stream, h)
        end
        startwrite(stream)
        for chunk in chunks
            write(stream, chunk)
        end
    end
    server = HTTP.serve!(stream_handler; stream=true, listenany=true)
    try
        port = HTTP.port(server)
        return f(port)
    finally
        close(server)
    end
end

@testset "Server Sent Events" begin
    payload = [
        "data: hello\n",
        "data: world\n",
        "id: 42\n",
        "\n",
        ": keep-alive\n",
        "event: update\n",
        "data: done\n",
        "retry: 1500\n",
        "foo: bar\n",
        "foo: baz\n",
        "\n",
        "data: closing\n"
    ]
    with_sse_server(payload) do port
        events = HTTP.SSEEvent[]
        resp = HTTP.request("GET", "http://$HOST:$port/stream"; sse_callback = event -> push!(events, event))
        @test resp.status == 200
        @test resp.body === HTTP.nobody
        @test length(events) == 3
        first_event, second_event, third_event = events
        @test first_event.event === nothing
        @test first_event.id == "42"
        @test first_event.retry === nothing
        @test first_event.data == "hello\nworld"
        @test first_event.fields["data"] == "hello\nworld"
        @test first_event.fields["id"] == "42"
        @test !haskey(first_event.fields, "retry")
        @test second_event.event == "update"
        @test second_event.id == "42"
        @test second_event.retry == 1500
        @test second_event.fields["foo"] == "bar\nbaz"
        @test second_event.fields["retry"] == "1500"
        @test third_event.event === nothing
        @test third_event.data == "closing"
        @test third_event.retry == 1500
        @test third_event.id == "42"
    end

    with_sse_server(["data: hi\n", "\n"], content_type="text/plain") do port
        events = HTTP.SSEEvent[]
        resp = HTTP.request("GET", "http://$HOST:$port/stream"; sse_callback = event -> push!(events, event))
        @test resp.status == 200
        @test resp.body === HTTP.nobody
        @test length(events) == 1
        @test events[1].data == "hi"
    end

    with_sse_server(["{\"error\":\"nope\"}"], content_type="application/json", status=400) do port
        captured = Ref{Union{Nothing,HTTP.Request}}(nothing)
        called = Ref(false)
        capturelayer(handler) = function(req; kw...)
            captured[] = req
            return handler(req; kw...)
        end
        stack = HTTP.stack(false, [capturelayer])
        pool = HTTP.Pool(1)
        err = try
            HTTP.request(stack, "GET", "http://$HOST:$port/stream"; sse_callback = _ -> (called[] = true), pool=pool)
            nothing
        catch e
            e
        end
        @test err isa HTTP.StatusError
        @test called[] == false
        @test captured[] !== nothing
        resp = captured[].response
        @test resp.status == 400
        @test String(resp.body) == "{\"error\":\"nope\"}"
    end

    with_sse_server(["data: boom\n", "\n"]) do port
        err = try
            HTTP.request("GET", "http://$HOST:$port/stream"; sse_callback = _ -> error("boom"))
            nothing
        catch e
            e
        end
        @test err isa HTTP.RequestError
        @test err.error isa ErrorException
        @test occursin("boom", sprint(showerror, err.error))
        @test err.request.response.body === HTTP.nobody
    end

    # UTF-8 BOM at the start of the stream should be ignored
    with_sse_server([UInt8[0xEF], UInt8[0xBB], UInt8[0xBF], "data: bom\n\n"]) do port
        events = HTTP.SSEEvent[]
        resp = HTTP.request("GET", "http://$HOST:$port/stream"; sse_callback = e -> push!(events, e))
        @test resp.status == 200
        @test length(events) == 1
        @test events[1].data == "bom"
    end

    # Per SSE spec, invalid retry values should be ignored, not cause an error
    with_sse_server(["retry: nope\n", "data: test\n", "\n"]) do port
        events = HTTP.SSEEvent[]
        resp = HTTP.request("GET", "http://$HOST:$port/stream"; sse_callback = e -> push!(events, e))
        @test resp.status == 200
        @test length(events) == 1
        @test events[1].data == "test"
        @test events[1].retry === nothing  # Invalid retry was ignored
    end

    # Also test that negative retry values are ignored
    with_sse_server(["retry: -100\n", "data: test\n", "\n"]) do port
        events = HTTP.SSEEvent[]
        resp = HTTP.request("GET", "http://$HOST:$port/stream"; sse_callback = e -> push!(events, e))
        @test resp.status == 200
        @test length(events) == 1
        @test events[1].retry === nothing  # Negative retry was ignored
    end

    compressed = read(GzipCompressorStream(IOBuffer("data: zipped\n\n")))
    with_sse_server([compressed]; headers=["Content-Encoding" => "gzip"]) do port
        events = HTTP.SSEEvent[]
        resp = HTTP.request("GET", "http://$HOST:$port/stream"; sse_callback = e -> push!(events, e))
        @test resp.status == 200
        @test length(events) == 1
        @test events[1].data == "zipped"
    end

    with_sse_server(String[]) do port
        events = HTTP.SSEEvent[]
        resp = HTTP.request("GET", "http://$HOST:$port/stream"; sse_callback = e -> push!(events, e))
        @test resp.status == 200
        @test isempty(events)
    end

    with_sse_server(["data: body\n", "\n"]) do port
        io = IOBuffer()
        err = try
            HTTP.request("GET", "http://$HOST:$port/stream"; response_stream=io, sse_callback = _ -> nothing)
            nothing
        catch e
            e
        end
        @test err isa HTTP.RequestError
        @test err.error isa ArgumentError

        err = try
            HTTP.request("GET", "http://$HOST:$port/stream"; iofunction = _ -> nothing, sse_callback = _ -> nothing)
            nothing
        catch e
            e
        end
        @test err isa HTTP.RequestError
        @test err.error isa ArgumentError
    end

    @testset "Client cancellation" begin
        server = HTTP.serve!(listenany=true) do request
            response = HTTP.Response(200)
            HTTP.sse_stream(response) do stream
                write(stream, HTTP.SSEEvent("first"))
                sleep(0.1)
                write(stream, HTTP.SSEEvent("second"))
            end
            return response
        end

        try
            port = HTTP.port(server)
            events = HTTP.SSEEvent[]
            resp = HTTP.request("GET", "http://$HOST:$port/"; sse_callback = (s, e) -> begin
                push!(events, e)
                close(s)
            end)
            @test resp.status == 200
            @test resp.body === HTTP.nobody
            @test length(events) == 1
            @test events[1].data == "first"
        finally
            close(server)
        end
    end
end

@testset "Server-Side SSE" begin
    # Test SSEEvent constructor with keyword arguments
    @testset "SSEEvent constructor" begin
        # Simple event with just data
        e = HTTP.SSEEvent("hello")
        @test e.data == "hello"
        @test e.event === nothing
        @test e.id === nothing
        @test e.retry === nothing

        # Event with all optional fields
        e = HTTP.SSEEvent("data"; event="message", id="123", retry=5000)
        @test e.data == "data"
        @test e.event == "message"
        @test e.id == "123"
        @test e.retry == 5000
    end

    # Test SSEStream write formatting
    @testset "SSEStream write formatting" begin
        stream = HTTP.SSEStream()

        # Simple data event
        write(stream, HTTP.SSEEvent("hello"))
        @test String(readavailable(stream)) == "data: hello\n\n"

        # Event with event type
        write(stream, HTTP.SSEEvent("data"; event="update"))
        @test String(readavailable(stream)) == "event: update\ndata: data\n\n"

        # Event with id
        write(stream, HTTP.SSEEvent("data"; id="42"))
        @test String(readavailable(stream)) == "id: 42\ndata: data\n\n"

        # Event with retry
        write(stream, HTTP.SSEEvent("data"; retry=3000))
        @test String(readavailable(stream)) == "retry: 3000\ndata: data\n\n"

        # Event with all fields
        write(stream, HTTP.SSEEvent("payload"; event="msg", id="99", retry=1000))
        @test String(readavailable(stream)) == "event: msg\nid: 99\nretry: 1000\ndata: payload\n\n"

        # Multiline data
        write(stream, HTTP.SSEEvent("line1\nline2\nline3"))
        @test String(readavailable(stream)) == "data: line1\ndata: line2\ndata: line3\n\n"

        close(stream)
    end

    # Test sse_stream helper
    @testset "sse_stream helper" begin
        response = HTTP.Response(200)
        stream = HTTP.sse_stream(response)

        @test response.body === stream
        @test HTTP.header(response, "Content-Type") == "text/event-stream"
        @test HTTP.header(response, "Cache-Control") == "no-cache"

        close(stream)
    end

    # Integration test: server-side SSE with client consumption
    @testset "Server-side SSE integration" begin
        server = HTTP.serve!(listenany=true) do request
            response = HTTP.Response(200)
            HTTP.sse_stream(response) do stream
                write(stream, HTTP.SSEEvent("first"))
                write(stream, HTTP.SSEEvent("second"; event="update", id="2"))
                write(stream, HTTP.SSEEvent("multi\nline\ndata"))
            end
            return response
        end

        try
            port = HTTP.port(server)
            events = HTTP.SSEEvent[]
            resp = HTTP.request("GET", "http://$HOST:$port/"; sse_callback = event -> push!(events, event))

            @test resp.status == 200
            @test resp.body === HTTP.nobody
            @test length(events) == 3

            @test events[1].data == "first"
            @test events[1].event === nothing
            @test events[1].id === nothing

            @test events[2].data == "second"
            @test events[2].event == "update"
            @test events[2].id == "2"

            @test events[3].data == "multi\nline\ndata"
        finally
            close(server)
        end
    end

    # Test that retry values are preserved through roundtrip
    @testset "SSE retry roundtrip" begin
        server = HTTP.serve!(listenany=true) do request
            response = HTTP.Response(200)
            HTTP.sse_stream(response) do stream
                write(stream, HTTP.SSEEvent("test"; retry=2500))
            end
            return response
        end

        try
            port = HTTP.port(server)
            events = HTTP.SSEEvent[]
            HTTP.request("GET", "http://$HOST:$port/"; sse_callback = event -> push!(events, event))

            @test length(events) == 1
            @test events[1].retry == 2500
        finally
            close(server)
        end
    end

    # Test streaming multiple events over time
    @testset "SSE streaming timing" begin
        server = HTTP.serve!(listenany=true) do request
            response = HTTP.Response(200)
            HTTP.sse_stream(response) do stream
                for i in 1:3
                    write(stream, HTTP.SSEEvent("event $i"; id=string(i)))
                    sleep(0.05) # Small delay between events
                end
            end
            return response
        end

        try
            port = HTTP.port(server)
            events = HTTP.SSEEvent[]
            HTTP.request("GET", "http://$HOST:$port/"; sse_callback = event -> push!(events, event))

            @test length(events) == 3
            for i in 1:3
                @test events[i].data == "event $i"
                @test events[i].id == string(i)
            end
        finally
            close(server)
        end
    end
end

end # module
