# A small HTTP/3 server for client tests: Reseau's QUIC listener with HTTP.jl's
# HTTP/3 framing and QPACK. Each request stream is passed, with its decoded
# request, to a handler that writes the response frames itself, so tests can
# also send malformed or unusual responses.

using HTTP
using Reseau

const _H3T = HTTP
const _H3T_QUIC = Reseau.QUIC
const _H3T_CERT = joinpath(@__DIR__, "resources", "unittests.crt")
const _H3T_KEY = joinpath(@__DIR__, "resources", "unittests.key")

struct _H3TestRequest
    headers::Vector{HTTP.HeaderField}
    body::Vector{UInt8}
    trailers::Vector{HTTP.HeaderField}
end

function _h3t_header(req::_H3TestRequest, name::AbstractString)
    for f in req.headers
        f.name == name && return f.value
    end
    return nothing
end

mutable struct _H3TestServer
    listener::_H3T_QUIC.Listener
    port::Int
    handler::Any
    # The settings each connection's control stream sends, and frames sent
    # after them.
    settings::Vector{Pair{UInt64,UInt64}}
    control_extra::Vector{UInt8}
    # Sent on the control stream instead of SETTINGS and `control_extra`.
    control_payload::Union{Nothing,Vector{UInt8}}
    close_control::Bool
    # Hand request streams to the handler unread, as `handler(stream, conn)`.
    raw::Bool
    # What clients sent on their control streams, and how connections ended.
    client_settings::Channel{Vector{Pair{UInt64,UInt64}}}
    conn_errors::Channel{Any}
    conns::Vector{_H3T_QUIC.Connection}
    controls::Vector{_H3T_QUIC.Stream}
    lock::ReentrantLock
    # Notified as connections are accepted and control streams opened.
    cond::Threads.Condition
    task::Task
end

function _h3t_frame(type, payload)
    out = UInt8[]
    _H3T._h3_append_frame!(out, UInt64(type), payload)
    return out
end

_h3t_headers_frame(fields::Vector{HTTP.HeaderField}) = _h3t_frame(_H3T._H3_FRAME_HEADERS, _H3T._qpack_encode(fields))
_h3t_headers_frame(pairs::Pair...) = _h3t_headers_frame([HTTP.HeaderField(String(k), String(v), false) for (k, v) in pairs])
_h3t_data_frame(data) = _h3t_frame(_H3T._H3_FRAME_DATA, Vector{UInt8}(data))

"""
Write a complete response: HEADERS with `:status` and `headers`, the body as
one DATA frame, trailers if any, then the FIN.
"""
function _h3t_respond!(s, status::Integer, headers::Vector{Pair{String,String}} = Pair{String,String}[], body = UInt8[];
        trailers::Vector{Pair{String,String}} = Pair{String,String}[], fin::Bool = true)
    out = _h3t_headers_frame((":status" => string(status)), headers...)
    isempty(body) || append!(out, _h3t_data_frame(body))
    isempty(trailers) || append!(out, _h3t_headers_frame(trailers...))
    write(s, out)
    fin && closewrite(s)
    return nothing
end

# Reads a request: HEADERS, DATA frames, and optional trailers until the FIN.
function _h3t_read_request(s)::_H3TestRequest
    headers = HTTP.HeaderField[]
    body = UInt8[]
    trailers = HTTP.HeaderField[]
    while true
        header = _H3T._h3_read_frame_header(s)
        header === nothing && break
        type, len = header
        if type == _H3T._H3_FRAME_HEADERS
            fields = _H3T._qpack_decode(_H3T._h3_read_payload(s, len, 1 << 20))
            isempty(headers) ? (headers = fields) : (trailers = fields)
        elseif type == _H3T._H3_FRAME_DATA
            append!(body, _H3T._h3_read_payload(s, len, 1 << 26))
        else
            _H3T._h3_skip!(s, len)
        end
    end
    return _H3TestRequest(headers, body, trailers)
end

function _h3t_serve_uni!(server::_H3TestServer, s)
    type = _H3T._h3_read_varint(s)
    if type == _H3T._H3_STREAM_CONTROL
        header = _H3T._h3_read_frame_header(s)
        header === nothing && return nothing
        type, len = header
        if type == _H3T._H3_FRAME_SETTINGS
            put!(server.client_settings, _H3T._h3_decode_settings(_H3T._h3_read_payload(s, len, 4096)))
        end
    end
    # Drain the rest; the client keeps its control stream open.
    while !isempty(readavailable(s))
    end
    return nothing
end

function _h3t_serve_conn!(server::_H3TestServer, conn)
    try
        _h3t_serve_conn_streams!(server, conn)
    catch err
        # A test may close the connection before the server is done with it.
        err isa _H3T_QUIC.ConnectionError || rethrow()
        put!(server.conn_errors, err)
    end
    return nothing
end

function _h3t_serve_conn_streams!(server::_H3TestServer, conn)
    control = _H3T_QUIC.open_stream(conn; bidi = false)
    out = UInt8[]
    _H3T._h3_append_varint!(out, _H3T._H3_STREAM_CONTROL)
    if server.control_payload === nothing
        append!(out, _h3t_frame(_H3T._H3_FRAME_SETTINGS, _H3T._h3_encode_settings(server.settings)))
        append!(out, server.control_extra)
    else
        append!(out, server.control_payload)
    end
    write(control, out)
    server.close_control && closewrite(control)
    lock(() -> push!(server.controls, control), server.lock)
    lock(() -> notify(server.cond), server.cond)
    tasks = Task[]
    try
        while true
            s = _H3T_QUIC.accept_stream(conn)
            push!(tasks, errormonitor(Threads.@spawn begin
                try
                    if _H3T_QUIC.isbidi(s) && server.raw
                        server.handler(s, conn)
                    elseif _H3T_QUIC.isbidi(s)
                        req = _h3t_read_request(s)
                        server.handler(req, s, conn)
                    else
                        _h3t_serve_uni!(server, s)
                    end
                catch err
                    (err isa _H3T_QUIC.ConnectionError || err isa _H3T_QUIC.StreamResetError ||
                        err isa _H3T_QUIC.StreamStoppedError) || rethrow()
                end
            end))
        end
    catch err
        err isa _H3T_QUIC.ConnectionError || rethrow()
        put!(server.conn_errors, err)
    end
    foreach(wait, tasks)
    return nothing
end

# Waits until `pred()` holds, `pred` reading server state under `server.lock`.
function _h3t_await(pred, server::_H3TestServer)
    lock(server.cond)
    try
        while !lock(pred, server.lock)
            wait(server.cond)
        end
    finally
        unlock(server.cond)
    end
end

"The server's `i`th accepted connection, waiting for it."
function _h3t_server_conn(server::_H3TestServer, i::Integer = 1)
    _h3t_await(() -> length(server.conns) >= i, server)
    return lock(() -> server.conns[i], server.lock)
end

"Send `bytes` on the control stream of the server's `i`th connection."
function _h3t_send_control!(server::_H3TestServer, bytes::Vector{UInt8}, i::Integer = 1)
    _h3t_await(() -> length(server.controls) >= i, server)
    write(lock(() -> server.controls[i], server.lock), bytes)
    return nothing
end

"""
    _h3t_server(handler; settings, control_extra) -> _H3TestServer

Serve HTTP/3 on an ephemeral loopback port, calling
`handler(request::_H3TestRequest, stream, conn)` for each request stream, or
`handler(stream, conn)` with the request unread when `raw` is set.
"""
function _h3t_server(handler;
        settings::Vector{Pair{UInt64,UInt64}} = Pair{UInt64,UInt64}[],
        control_extra::Vector{UInt8} = UInt8[],
        control_payload::Union{Nothing,Vector{UInt8}} = nothing,
        close_control::Bool = false,
        raw::Bool = false,
        max_streams_bidi::Integer = 100)
    config = Reseau.TLS.Config(verify_peer = false, cert_file = _H3T_CERT, key_file = _H3T_KEY, alpn_protocols = ["h3"])
    listener = _H3T_QUIC.listen(Reseau.UDP.loopback_addr(0), config; max_streams_bidi)
    port = Int(_H3T_QUIC.local_addr(listener).port)
    server = _H3TestServer(listener, port, handler, settings, control_extra, control_payload, close_control, raw,
        Channel{Vector{Pair{UInt64,UInt64}}}(Inf), Channel{Any}(Inf), _H3T_QUIC.Connection[], _H3T_QUIC.Stream[],
        ReentrantLock(), Threads.Condition(), current_task())
    server.task = errormonitor(Threads.@spawn begin
        conn_tasks = Task[]
        try
            while true
                conn = _H3T_QUIC.accept(listener)
                lock(() -> push!(server.conns, conn), server.lock)
                lock(() -> notify(server.cond), server.cond)
                push!(conn_tasks, errormonitor(Threads.@spawn _h3t_serve_conn!(server, conn)))
            end
        catch err
            err isa ArgumentError || rethrow()
        end
        foreach(wait, conn_tasks)
    end)
    return server
end

_h3t_address(server::_H3TestServer) = "127.0.0.1:$(server.port)"

function _h3t_close(server::_H3TestServer)
    close(server.listener)
    for conn in lock(() -> copy(server.conns), server.lock)
        close(conn; code = _H3T._H3_NO_ERROR)
    end
    wait(server.task)
    return nothing
end

_h3t_client_tls() = Reseau.TLS.Config(verify_peer = false)

function _h3t_connect(server::_H3TestServer)
    return HTTP.connect_h3!(_h3t_address(server); tls_config = _h3t_client_tls())
end
