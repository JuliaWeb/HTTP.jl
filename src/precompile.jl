using PrecompileTools: @setup_workload, @compile_workload

try
    @setup_workload begin
        function _precompile_wait_port(server::Server; timeout_s::Float64 = 5.0)::Int
            deadline = time() + timeout_s
            while time() < deadline
                try
                    value = port(server)
                    value > 0 && return value
                catch
                end
                sleep(0.01)
            end
            return port(server)
        end

        function _precompile_body_string(body::AbstractBody)::String
            out = UInt8[]
            buf = Vector{UInt8}(undef, 256)
            while true
                n = body_read!(body, buf)
                n == 0 && break
                append!(out, @view(buf[1:n]))
            end
            try
                body_close!(body)
            catch
            end
            return String(out)
        end

        _precompile_body_string(body::AbstractVector{UInt8}) = String(body)
        _precompile_body_string(body::AbstractString) = String(body)

        function _precompile_text_response(
            text::AbstractString;
            status::Integer = 200,
            proto_major::Integer = 1,
            proto_minor::Integer = 1,
        )::Response
            payload = String(text)
            body = BytesBody(collect(codeunits(payload)))
            return Response(
                status;
                body = body,
                content_length = ncodeunits(payload),
                proto_major = proto_major,
                proto_minor = proto_minor,
            )
        end

        function _precompile_echo_handler(req::Request)::Response
            payload = _precompile_body_string(req.body)
            return _precompile_text_response("echo:" * getparam(req, "name") * ":" * payload)
        end

        function _precompile_stream_handler(stream::Stream)::Nothing
            request = startread(stream)
            payload = read(stream, String)
            setstatus(stream, 200)
            setheader(stream, "Content-Type", "text/plain; charset=utf-8")
            write(stream, "stream:" * request.target * ":" * payload)
            return nothing
        end

        request_router = Router()
        register!(request_router, "GET", "/hello/{name}", req -> _precompile_text_response("hello:" * getparam(req, "name")))
        register!(request_router, "POST", "/echo/{name}", limitrequestbody(8)(_precompile_echo_handler))

        request_server = serve!(request_router, "127.0.0.1", 0; listenany = true)
        stream_server = listen!("127.0.0.1", 0; listenany = true) do stream
            _precompile_stream_handler(stream)
        end

        temp_dir = mktempdir()
        write(joinpath(temp_dir, "hello.txt"), "static hello")
        file_server = serve!(fileserver(temp_dir; etag = :weak_stat), "127.0.0.1", 0; listenany = true)

        h2_server = serve!("127.0.0.1", 0; listenany = true) do request
            _precompile_text_response("h2:" * request.target; proto_major = 2, proto_minor = 0)
        end

        request_address = "127.0.0.1:$(_precompile_wait_port(request_server))"
        stream_address = "127.0.0.1:$(_precompile_wait_port(stream_server))"
        file_address = "127.0.0.1:$(_precompile_wait_port(file_server))"
        h2_address = "127.0.0.1:$(_precompile_wait_port(h2_server))"

        client = Client(
            transport = Transport(max_idle_per_host = 4, max_idle_total = 4),
            prefer_http2 = false,
        )
        h2_client = Client(
            transport = Transport(max_idle_per_host = 4, max_idle_total = 4),
            prefer_http2 = true,
        )

        try
            @compile_workload begin
                hello = get("http://$(request_address)/hello/jane"; client = client)
                @assert hello.status == 200
                @assert _precompile_body_string(hello.body) == "hello:jane"

                echo = post("http://$(request_address)/echo/jane"; client = client, body = "ping")
                @assert echo.status == 200
                @assert _precompile_body_string(echo.body) == "echo:jane:ping"

                streamed = open(:POST, "http://$(stream_address)/stream"; client = client, retry = false) do stream
                    write(stream, "payload")
                end
                @assert streamed.status == 200

                static_resp = get("http://$(file_address)/hello.txt"; client = client)
                @assert static_resp.status == 200
                @assert _precompile_body_string(static_resp.body) == "static hello"

                h2_resp = get("http://$(h2_address)/h2"; client = h2_client, protocol = :h2)
                @assert h2_resp.status == 200
                @assert h2_resp.proto_major == 2
                @assert _precompile_body_string(h2_resp.body) == "h2:/h2"
            end
        finally
            try
                close(client)
            catch
            end
            try
                close(h2_client)
            catch
            end
            for server in (request_server, stream_server, file_server, h2_server)
                try
                    forceclose(server)
                catch
                end
            end
            for _ in 1:8
                yield()
            end
            GC.gc()
            try
                IOPoll.shutdown!()
            catch
            end
            for _ in 1:4
                yield()
            end
            rm(temp_dir; force = true, recursive = true)
        end
    end
catch err
    @info "Ignoring an error that occurred during the precompilation workload" exception=(err, catch_backtrace())
end
