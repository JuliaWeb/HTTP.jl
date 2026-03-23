# High-level HTTP client orchestration, HTTP/2 integration, cookies, response sinks, and convenience APIs.
export Client
export ClientTrace
export Cookie
export CookieJar
export do!
export get!
export StatusError
export TooManyRedirectsError
export request
export get
export head
export post
export put
export patch
export delete
export options

"""
    ClientTrace(; ...)

Optional callback hooks for client request lifecycle events.

Each field may be `nothing` or a callback function. Callbacks are invoked
synchronously from the request path, so they should stay lightweight and may
throw to abort a request.
"""
struct ClientTrace
    on_get_conn::Union{Nothing,Function}
    on_got_conn::Union{Nothing,Function}
    on_wrote_request::Union{Nothing,Function}
    on_got_first_response_byte::Union{Nothing,Function}
end

"""
    Client(; ...)

High-level HTTP client with transport pooling, redirect policy, cookies, and
optional HTTP/2.

Keyword arguments:
- `transport`: lower-level HTTP/1 transport/pool implementation
- `check_redirect`: optional callback deciding whether a redirect should be
  followed
- `cookiejar`: cookie jar implementation, or `nothing` to disable cookies
- `max_redirects`: maximum redirect hops before failing
- `trace`: optional lifecycle callback bundle
- `prefer_http2`: whether secure requests should try HTTP/2 when available
"""
mutable struct Client
    transport::Transport
    check_redirect::Union{Nothing,Function}
    cookiejar::Union{Nothing,CookieJar}
    max_redirects::Int
    trace::Union{Nothing,ClientTrace}
    prefer_http2::Bool
    h2_lock::ReentrantLock
    h2_conns::Dict{String,Vector{H2Connection}}
end

function ClientTrace(;
    on_get_conn::Union{Nothing,Function}=nothing,
    on_got_conn::Union{Nothing,Function}=nothing,
    on_wrote_request::Union{Nothing,Function}=nothing,
    on_got_first_response_byte::Union{Nothing,Function}=nothing,
)
    return ClientTrace(on_get_conn, on_got_conn, on_wrote_request, on_got_first_response_byte)
end

function Client(;
    transport::Transport=Transport(proxy=ProxyFromEnvironment()),
    check_redirect::Union{Nothing,Function}=nothing,
    cookiejar::Union{Nothing,CookieJar}=CookieJar(),
    max_redirects::Integer=10,
    trace::Union{Nothing,ClientTrace}=nothing,
    prefer_http2::Bool=true,
)
    max_redirects >= 0 || throw(ArgumentError("max_redirects must be >= 0"))
    return Client(transport, check_redirect, cookiejar, Int(max_redirects), trace, prefer_http2, ReentrantLock(), Dict{String,Vector{H2Connection}}())
end

struct _UseTransportProxy end

const _USE_TRANSPORT_PROXY = _UseTransportProxy()


function _redirect_policy(
    client::Client;
    redirect_limit::Union{Nothing,Integer}=nothing,
    redirect_method=nothing,
    forwardheaders::Bool=true,
)::_RedirectPolicy
    max_redirects = redirect_limit === nothing ? client.max_redirects : Int(redirect_limit)
    max_redirects >= 0 || throw(ArgumentError("redirect_limit must be >= 0"))
    callback = client.check_redirect
    method_override, preserve_method = _normalize_redirect_method_override(redirect_method)
    return _RedirectPolicy(callback, max_redirects, method_override, preserve_method, forwardheaders)
end

function _proxy_config_for_request(client::Client, proxy)::ProxyConfig
    proxy === _USE_TRANSPORT_PROXY && return client.transport.proxy
    return _normalize_proxy_config(proxy)
end

function Base.close(client::Client)
    close(client.transport)
    lock(client.h2_lock)
    try
        for (_, conns) in client.h2_conns
            for conn in conns
                try
                    close(conn)
                catch
                end
            end
        end
        empty!(client.h2_conns)
    finally
        unlock(client.h2_lock)
    end
    return nothing
end

@inline function _h2_key(plan::_ProxyPlan)::String
    return string("h2|", plan.pool_key)
end

function _acquire_h2_conn!(
    client::Client,
    plan::_ProxyPlan,
    address::String,
    secure::Bool;
    request::Union{Nothing,Request}=nothing,
    server_name::Union{Nothing,String}=nothing,
)::H2Connection
    key = _h2_key(plan)
    base_host_resolver = client.transport.host_resolver
    connect_host_resolver = request === nothing ? base_host_resolver : _request_connect_host_resolver(base_host_resolver, request::Request)
    connect_deadline_ns = request === nothing ? _phase_deadline_ns(base_host_resolver.timeout_ns, base_host_resolver.deadline_ns) : _request_connect_phase_deadline_ns(base_host_resolver, request::Request)
    tls_handshake_timeout_ns = request === nothing ? Int64(0) : _request_connect_phase_timeout_ns(base_host_resolver, request::Request)
    lock(client.h2_lock)
    try
        conns = get(() -> H2Connection[], client.h2_conns, key)
        i = 1
        while i <= length(conns)
            existing = conns[i]
            if !_h2_conn_available(existing::H2Connection)
                if !_h2_conn_reusable(existing::H2Connection)
                    deleteat!(conns, i)
                    try
                        close(existing::H2Connection)
                    catch
                    end
                    continue
                end
            else
                return existing::H2Connection
            end
            i += 1
        end
        tls_cfg = if secure
            _make_tls_config_for_h2(
                client.transport.tls_config,
                address;
                server_name=server_name,
                handshake_timeout_ns=tls_handshake_timeout_ns,
            )
        else
            nothing
        end
        conn = nothing
        conn = if plan.mode == _ProxyPlanMode.DIRECT
            connect_h2!(
                address;
                secure=secure,
                host_resolver=connect_host_resolver,
                tls_config=tls_cfg,
                connect_deadline_ns=connect_deadline_ns,
            )
        elseif plan.mode == _ProxyPlanMode.HTTP_TUNNEL
            proxy = plan.proxy
            proxy === nothing && throw(ProtocolError("proxy CONNECT tunnel is missing proxy config"))
            tcp = TCP.connect(connect_host_resolver, "tcp", plan.first_hop_address)
            try
                _perform_http_connect_tunnel!(tcp, proxy::_ProxyTarget, address, connect_deadline_ns)
                connect_h2!(tcp, address; secure=secure, tls_config=tls_cfg, connect_deadline_ns=connect_deadline_ns)
            catch
                try
                    TCP.close(tcp)
                catch
                end
                rethrow()
            end
        else
            throw(ArgumentError("HTTP/2 is not supported for proxy plan mode $(plan.mode)"))
        end
        push!(conns, conn)
        client.h2_conns[key] = conns
        return conn::H2Connection
    finally
        unlock(client.h2_lock)
    end
end

@inline function _should_fallback_h2_to_h1(err)::Bool
    return err isa H2NegotiationError
end

function _drop_h2_conn!(client::Client, plan::_ProxyPlan, target::Union{Nothing,H2Connection}=nothing)
    key = _h2_key(plan)
    lock(client.h2_lock)
    try
        conns = get(() -> H2Connection[], client.h2_conns, key)
        kept = H2Connection[]
        for conn in conns
            if target === nothing || conn === target
                try
                    close(conn)
                catch
                end
            else
                push!(kept, conn)
            end
        end
        if isempty(kept)
            pop!(client.h2_conns, key, H2Connection[])
        else
            client.h2_conns[key] = kept
        end
    finally
        unlock(client.h2_lock)
    end
    return nothing
end

function _use_h2(client::Client, secure::Bool, protocol::Symbol)::Bool
    protocol == :h1 && return false
    protocol == :h2 && return true
    protocol == :auto || throw(ArgumentError("protocol must be :auto, :h1, or :h2"))
    secure || return false
    return client.prefer_http2
end

function _host_path_from_request(address::String, request::Request)::Tuple{String,String}
    host, _ = HostResolvers.split_host_port(address)
    target = request.target
    if isempty(target)
        return host, "/"
    end
    startswith(target, "/") && return host, target
    return host, "/$target"
end

function _normalize_cookies_input(cookies)
    if cookies isa Bool
        return cookies
    end
    cookies isa AbstractDict || throw(ArgumentError("cookies must be true, false, or an AbstractDict of cookie name/value pairs"))
    normalized = Cookie[]
    for (name, value) in pairs(cookies)
        push!(normalized, Cookie(name, value))
    end
    return normalized
end

function _effective_cookiejar(client::Union{Nothing,Client}, cookiejar::Union{Nothing,CookieJar})::Union{Nothing,CookieJar}
    cookiejar !== nothing && return cookiejar
    client === nothing && return COOKIEJAR
    return (client::Client).cookiejar
end

function _cookie_header(
    cookiejar::Union{Nothing,CookieJar},
    cookies::Union{Bool,Vector{Cookie}},
    secure::Bool,
    host::String,
    path::String,
)::Union{Nothing,String}
    cookies === false && return nothing
    merged = Cookie[]
    if cookiejar !== nothing
        scheme = secure ? "https" : "http"
        append!(merged, getcookies!(cookiejar, scheme, host, path))
    end
    if cookies !== true
        append!(merged, cookies::Vector{Cookie})
    end
    isempty(merged) && return nothing
    return stringify("", merged)
end

function _store_set_cookies!(
    cookiejar::Union{Nothing,CookieJar},
    cookies::Union{Bool,Vector{Cookie}},
    secure::Bool,
    host::String,
    path::String,
    headers::Headers,
)
    cookies === false && return nothing
    cookiejar === nothing && return nothing
    scheme = secure ? "https" : "http"
    setcookies!(cookiejar::CookieJar, scheme, host, path, headers)
    return nothing
end

function _trace_call(trace::Union{Nothing,ClientTrace}, field::Symbol, args...)
    trace === nothing && return nothing
    callback = getfield(trace::ClientTrace, field)
    callback === nothing && return nothing
    callback(args...)
    return nothing
end

function _clone_bytes_body(body::BytesBody)::BytesBody
    remaining = (length(body.data) - body.next_index) + 1
    remaining <= 0 && return BytesBody(UInt8[])
    copied = Vector{UInt8}(undef, remaining)
    copyto!(copied, 1, body.data, body.next_index, remaining)
    return BytesBody(copied)
end

function _clone_body(body::AbstractBody)::AbstractBody
    body isa EmptyBody && return EmptyBody()
    body isa BytesBody && return _clone_bytes_body(body::BytesBody)
    throw(ProtocolError("request body is not replayable for redirect"))
end

function _copy_request(request::Request)
    return _request_nocopy(
        request.method,
        request.target,
        copy(request.headers),
        copy(request.trailers),
        _clone_body(request.body),
        request.host,
        request.content_length,
        request.proto_major,
        request.proto_minor,
        request.close,
        request.context,
    )
end

function _copy_request_shallow_body(request::Request)
    return _request_nocopy(
        request.method,
        request.target,
        copy(request.headers),
        copy(request.trailers),
        request.body,
        request.host,
        request.content_length,
        request.proto_major,
        request.proto_minor,
        request.close,
        request.context,
    )
end

@inline function _is_nonreplayable_body_error(err)::Bool
    err isa ProtocolError || return false
    return occursin("request body is not replayable for redirect", (err::ProtocolError).message)
end

function _copy_request_for_send(request::Request; allow_nonreplayable::Bool=false)::Request
    if allow_nonreplayable
        try
            return _copy_request(request)
        catch err
            _is_nonreplayable_body_error(err) || rethrow(err)
            return _copy_request_shallow_body(request)
        end
    end
    return _copy_request(request)
end

"""
    _do_incoming!(client, address, request; secure=false, server_name=nothing, protocol=:auto)

Send `request` with redirect handling and return the final low-level
`_IncomingResponse`.

This method preserves streaming bodies, so callers are responsible for draining
or closing `response.rawbody` or the wrapped public body derived from it.

`protocol` accepts `:auto`, `:h1`, or `:h2`. In `:auto` mode the client may try
HTTP/2 first for secure requests and fall back to HTTP/1 when negotiation says
that h2 is unavailable.
"""
function _do_incoming!(
    client::Client,
    address::AbstractString,
    request::Request;
    secure::Bool=false,
    server_name::Union{Nothing,AbstractString}=nothing,
    protocol::Symbol=:auto,
    redirect_policy::_RedirectPolicy=_redirect_policy(client),
    retry_controller=nothing,
    proxy_config::ProxyConfig=client.transport.proxy,
    cookies::Union{Bool,Vector{Cookie}}=true,
    cookiejar::Union{Nothing,CookieJar}=client.cookiejar,
)
    current_address = String(address)
    initial_address = current_address
    current_secure = secure
    explicit_server_name = server_name !== nothing
    current_server_name = explicit_server_name ? String(server_name::AbstractString) : _host_for_sni(current_address)
    current_request = _copy_request_shallow_body(request)
    controller = retry_controller
    previous_response = nothing
    retry_attempt = 1
    retry_token = nothing
    config = _request_context_verbose_config(request.context)
    _verbose_line!(config, 1, string("request ", _verbose_request_summary(current_request, _request_url(current_secure, current_address, current_request.target))))
    for redirect_count in 0:redirect_policy.max_redirects
        while true
            send_request = _copy_request_for_send(current_request; allow_nonreplayable=retry_attempt == 1)
            request_url = _request_url(current_secure, current_address, current_request.target)
            proxy_plan = _proxy_plan(proxy_config, current_secure, current_address)
            use_h2 = _use_h2(client, current_secure, protocol) && proxy_plan.mode != _ProxyPlanMode.HTTP_FORWARD
            exchange = _begin_verbose_exchange!(send_request, use_h2 ? :h2 : :h1, retry_attempt, redirect_count, request_url)
            use_h2 && (send_request = _wrap_verbose_request_body!(send_request, exchange))
            _verbose_line!(config, 1, string("attempt ", retry_attempt, " via ", use_h2 ? "h2" : "h1", " ", _verbose_request_summary(send_request, request_url)))
            host, path = _host_path_from_request(current_address, current_request)
            cookie_value = _cookie_header(cookiejar, cookies, current_secure, host, path)
            cookie_value === nothing || setheader(send_request.headers, "Cookie", cookie_value)
            _trace_call(client.trace, :on_get_conn, current_address, current_secure)
            response = try
                if use_h2
                    conn = nothing
                    try
                        conn = _acquire_h2_conn!(client, proxy_plan, current_address, current_secure; request=send_request, server_name=current_server_name)
                        _attach_verbose_to_incoming_response(_h2_roundtrip_incoming!(conn::H2Connection, send_request), exchange; capture_body=true)
                    catch err
                        _drop_h2_conn!(client, proxy_plan, conn)
                        if protocol == :auto && _should_fallback_h2_to_h1(err)
                            _verbose_line!(config, 1, string("h2 fallback to h1 after ", sprint(showerror, err)))
                            send_request = _copy_request_for_send(current_request; allow_nonreplayable=retry_attempt == 1)
                            exchange = _begin_verbose_exchange!(send_request, :h1, retry_attempt, redirect_count, request_url)
                            _attach_verbose_to_incoming_response(_roundtrip_incoming!(
                                client.transport,
                                current_address,
                                send_request;
                                secure=current_secure,
                                server_name=current_server_name,
                                proxy_config=proxy_config,
                            ), exchange; capture_body=false)
                        else
                            rethrow(err)
                        end
                    end
                else
                    _attach_verbose_to_incoming_response(_roundtrip_incoming!(
                        client.transport,
                        current_address,
                        send_request;
                        secure=current_secure,
                        server_name=current_server_name,
                        proxy_config=proxy_config,
                    ), exchange; capture_body=false)
                end
            catch err
                exchange !== nothing && _verbose_log_request_dump!(exchange::_VerboseExchangeState)
                _verbose_line!(config, 1, string("attempt ", retry_attempt, " failed: ", sprint(showerror, err)))
                if controller !== nothing
                    ctrl = controller::_RetryController
                    _release_retry_token!(ctrl, retry_token, err)
                end
                retry_token = nothing
                if controller !== nothing
                    ctrl = controller::_RetryController
                    if _should_retry_request_attempt(ctrl, retry_attempt, current_request, err, nothing)
                        scheduled, next_token = _arm_request_retry!(ctrl, current_address, current_request, retry_attempt, nothing)
                        if scheduled
                            _verbose_line!(config, 1, string("retrying after error on attempt ", retry_attempt))
                            retry_attempt += 1
                            retry_token = next_token
                            continue
                        end
                    end
                end
                rethrow(err)
            end
            response = _annotate_incoming_response(
                response,
                request_url,
                previous_response,
                redirect_count,
            )
            _trace_call(client.trace, :on_got_conn, current_address, current_secure)
            _trace_call(client.trace, :on_wrote_request, send_request.method, send_request.target)
            _trace_call(client.trace, :on_got_first_response_byte, response.head.status)
            _verbose_line!(config, 1, string("response ", _verbose_response_summary(response.head), " for ", request_url))
            _store_set_cookies!(cookiejar, cookies, current_secure, host, path, response.head.headers)
            status_response = _retry_policy_response(response, current_request)
            if controller !== nothing
                ctrl = controller::_RetryController
                if _retryable_status(status_response.status)
                    _release_retry_token!(ctrl, retry_token, status_response)
                else
                    _release_retry_token!(ctrl, retry_token)
                end
            end
            retry_token = nothing
            if controller !== nothing
                ctrl = controller::_RetryController
                should_retry = try
                    _should_retry_request_attempt(ctrl, retry_attempt, current_request, nothing, status_response)
                catch
                    try
                        body_close!(response.rawbody)
                    catch
                    end
                    rethrow()
                end
                if should_retry
                    scheduled, next_token = _arm_request_retry!(ctrl, current_address, current_request, retry_attempt, status_response)
                    if scheduled
                        _verbose_line!(config, 1, string("retrying after response status ", status_response.status, " on attempt ", retry_attempt))
                        retry_attempt += 1
                        retry_token = next_token
                        try
                            body_close!(response.rawbody)
                        catch
                        end
                        continue
                    end
                end
            end
            if !_is_redirect_status(response.head.status)
                return response
            end
            location = header(response.head.headers, "Location", nothing)
            (location === nothing || isempty(location::String)) && return response
            redirect_policy.max_redirects == 0 && return response
            redirect_count == redirect_policy.max_redirects && throw(TooManyRedirectsError(redirect_policy.max_redirects, _streaming_response(response)))
            if redirect_policy.check_redirect !== nothing
                proceed = (redirect_policy.check_redirect::Function)(_streaming_response(response), current_request, location)
                proceed isa Bool || throw(ProtocolError("check_redirect callback must return Bool"))
                proceed || return response
            end
            next_method = _rewrite_method_for_redirect(current_request.method, response.head.status, redirect_policy)
            if _redirect_reuses_request_body(next_method) && !_redirect_body_replayable(current_request)
                return response
            end
            previous_response = _streaming_response(response)
            body_close!(response.rawbody)
            _verbose_line!(config, 1, string("redirect ", response.head.status, " -> ", location::String))
            previous_secure = current_secure
            previous_address = current_address
            previous_target = current_request.target
            current_address, current_secure, next_target = _resolve_redirect_target(current_address, current_secure, location, current_request.target)
            if !explicit_server_name
                current_server_name = _host_for_sni(current_address)
            end
            current_request = _prepare_request_for_redirect(current_request, response.head.status, next_target, redirect_policy)
            existing_ref = header(current_request.headers, "Referer", nothing)
            next_ref = _redirect_referer(previous_secure, previous_address, previous_target, current_secure, existing_ref)
            if next_ref === nothing
                removeheader(current_request.headers, "Referer")
            else
                setheader(current_request.headers, "Referer", next_ref::String)
            end
            if !_should_copy_sensitive_headers_on_redirect(initial_address, current_address)
                _strip_sensitive_redirect_headers!(current_request.headers)
            end
            current_request.host = current_address
            break
        end
    end
    throw(ProtocolError("unexpected redirect loop termination"))
end

"""
    do!(client, address, request; ...) -> Response

Execute a prepared `Request` through an existing `Client`.

This is the low-level companion to [`request`](@ref) for callers that already
own the address/target split and want to reuse client state directly.
"""
function do!(
    client::Client,
    address::AbstractString,
    request::Request;
    secure::Bool=false,
    server_name::Union{Nothing,AbstractString}=nothing,
    protocol::Symbol=:auto,
    proxy=_USE_TRANSPORT_PROXY,
    redirect_limit::Union{Nothing,Integer}=nothing,
    redirect_method=nothing,
    forwardheaders::Bool=true,
    cookies=true,
    cookiejar::Union{Nothing,CookieJar}=nothing,
    verbose=false,
    verbose_body_nbytes::Integer=_VERBOSE_DEFAULT_BODY_NBYTES,
    verbose_io::IO=stderr,
)
    config = _verbose_config(; verbose=verbose, verbose_body_nbytes=verbose_body_nbytes, verbose_io=verbose_io)
    config === nothing || _set_request_context_verbose_config!(request.context, config)
    normalized_cookies = _normalize_cookies_input(cookies)
    policy = _redirect_policy(
        client;
        redirect_limit=redirect_limit,
        redirect_method=redirect_method,
        forwardheaders=forwardheaders,
    )
    proxy_config = _proxy_config_for_request(client, proxy)
    effective_cookiejar = _effective_cookiejar(client, cookiejar)
    return _streaming_response(_do_incoming!(
        client,
        address,
        request;
        secure=secure,
        server_name=server_name,
        protocol=protocol,
        redirect_policy=policy,
        proxy_config=proxy_config,
        cookies=normalized_cookies,
        cookiejar=effective_cookiejar,
    ))
end

"""
    get!(client, address, target; secure=false, protocol=:auto)

Convenience GET request using an existing `Client`.

Returns the same low-level `Response` shape as `do!`.
"""
function get!(client::Client, address::AbstractString, target::AbstractString; secure::Bool=false, protocol::Symbol=:auto, kwargs...)
    request = Request("GET", target; host=String(address), body=EmptyBody(), content_length=0)
    return do!(client, address, request; secure=secure, protocol=protocol, kwargs...)
end

import Base: get

"""
    StatusError

Raised when `status_exception=true` and the response status indicates failure.
"""
struct StatusError <: Exception
    response::Response
end

function Base.showerror(io::IO, err::StatusError)
    resp = err.response
    print(io, "http status error: ", resp.status, " for ", resp.request.method, " ", resp.url)
    return nothing
end

"""
    TooManyRedirectsError

Raised when redirect following is enabled and the client exceeds the configured
redirect limit. The final redirect response is attached for inspection.
"""
struct TooManyRedirectsError <: Exception
    limit::Int
    response::Response
end

function Base.showerror(io::IO, err::TooManyRedirectsError)
    resp = err.response
    print(io, "http too many redirects after ", err.limit, " hops for ", resp.request.method, " ", resp.url)
    return nothing
end


function _annotate_incoming_response(
    incoming::_IncomingResponse{B},
    request_url::String,
    previous::Union{Nothing,Response},
    redirect_count::Int,
)::_IncomingResponse{B} where {B<:AbstractBody}
    head = incoming.head
    return _IncomingResponse(
        _IncomingResponseHead(
            head.status,
            head.reason,
            head.headers,
            head.trailers,
            head.content_length,
            head.proto_major,
            head.proto_minor,
            head.close,
            head.request,
            request_url,
            previous,
            redirect_count,
        ),
        incoming.rawbody,
    )
end

const _DEFAULT_CLIENT_LOCK = ReentrantLock()
const _DEFAULT_CLIENT = Ref{Union{Nothing,Client}}(nothing)
const COOKIEJAR = CookieJar()

function _default_client!()::Client
    lock(_DEFAULT_CLIENT_LOCK)
    try
        existing = _DEFAULT_CLIENT[]
        existing === nothing || return existing::Client
        created = Client()
        _DEFAULT_CLIENT[] = created
        return created
    finally
        unlock(_DEFAULT_CLIENT_LOCK)
    end
end

function _status_throws(resp::Response)::Bool
    return resp.status >= 300 && !_is_redirect_status(resp.status)
end

function _read_all_response_bytes(io::IO)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 8192)
    while true
        n = readbytes!(io, buf, length(buf))
        n == 0 && return out
        append!(out, @view(buf[1:n]))
    end
end

const _MAX_EAGER_RESPONSE_PREALLOC = Int64(1 << 20)

function _read_all_response_bytes(body::AbstractBody; content_length_hint::Int64=Int64(-1))::Vector{UInt8}
    if 0 <= content_length_hint <= _MAX_EAGER_RESPONSE_PREALLOC
        out = Vector{UInt8}(undef, Int(content_length_hint))
        n = _copy_response_bytes!(out, body)
        n == content_length_hint || resize!(out, Int(n))
        return out
    end
    out = UInt8[]
    content_length_hint > 0 && sizehint!(out, Int(min(content_length_hint, _MAX_EAGER_RESPONSE_PREALLOC)))
    buf = Vector{UInt8}(undef, 8192)
    while true
        n = body_read!(body, buf)
        n == 0 && return out
        append!(out, @view(buf[1:n]))
    end
end

function _copy_response_bytes!(dest::IO, io::IO)::Int64
    buf = Vector{UInt8}(undef, 8192)
    total = Int64(0)
    while true
        n = readbytes!(io, buf, length(buf))
        n == 0 && return total
        total += n
        write(dest, view(buf, 1:n))
    end
end

function _copy_response_bytes!(dest::AbstractVector{UInt8}, io::IO)::Int64
    buf = Vector{UInt8}(undef, 8192)
    total = 0
    capacity = length(dest)
    while true
        n = readbytes!(io, buf, length(buf))
        n == 0 && break
        needed = total + n
        needed <= capacity || throw(ArgumentError("Unable to grow response stream IOBuffer $(capacity) large enough for response body size: $(needed)"))
        copyto!(dest, total + 1, buf, 1, n)
        total = needed
    end
    dest isa Vector{UInt8} && resize!(dest::Vector{UInt8}, total)
    return Int64(total)
end

function _copy_response_bytes!(dest::IO, body::AbstractBody)::Int64
    buf = Vector{UInt8}(undef, 8192)
    total = Int64(0)
    while true
        n = body_read!(body, buf)
        n == 0 && return total
        total += n
        write(dest, view(buf, 1:n))
    end
end

function _copy_response_bytes!(dest::AbstractVector{UInt8}, body::AbstractBody)::Int64
    buf = Vector{UInt8}(undef, 8192)
    total = 0
    capacity = length(dest)
    while true
        n = body_read!(body, buf)
        n == 0 && break
        needed = total + n
        needed <= capacity || throw(ArgumentError("Unable to grow response stream IOBuffer $(capacity) large enough for response body size: $(needed)"))
        copyto!(dest, total + 1, buf, 1, n)
        total = needed
    end
    dest isa Vector{UInt8} && resize!(dest::Vector{UInt8}, total)
    return Int64(total)
end

function _response_content_encoding(headers::Headers, decompress::Union{Nothing,Bool})::Union{Nothing,Symbol}
    decompress === false && return nothing
    encoding = header(headers, "Content-Encoding", nothing)
    encoding === nothing && return nothing
    normalized = lowercase(strip(encoding))
    if normalized == "gzip" || normalized == "x-gzip"
        return :gzip
    elseif normalized == "deflate" || normalized == "x-deflate"
        return :deflate
    end
    return nothing
end

function _should_decompress_response(headers::Headers, decompress::Union{Nothing,Bool})::Bool
    return _response_content_encoding(headers, decompress) !== nothing
end

@inline function _closed_bufferstream_error(err)::Bool
    return err isa Base.IOError && occursin("stream is closed or unusable", sprint(showerror, err))
end

function _pump_response_body!(stream::Base.BufferStream, body::AbstractBody)::Nothing
    buf = Vector{UInt8}(undef, 8192)
    try
        while true
            n = body_read!(body, buf)
            n == 0 && break
            try
                write(stream, view(buf, 1:n))
            catch err
                _closed_bufferstream_error(err) && break
                rethrow()
            end
        end
    finally
        try
            body_close!(body)
        catch
        end
        try
            close(stream)
        catch
        end
    end
    return nothing
end

mutable struct _BodyIO{B<:AbstractBody} <: IO
    body::B
    buf::Vector{UInt8}
    next_index::Int
    filled::Int
    @atomic saw_eof::Bool
    @atomic closed::Bool
end

function _BodyIO(body::B; buffer_bytes::Integer=8192) where {B<:AbstractBody}
    n = Int(buffer_bytes)
    n > 0 || throw(ArgumentError("buffer_bytes must be > 0"))
    return _BodyIO{B}(body, Vector{UInt8}(undef, n), 1, 0, false, false)
end

@inline function _buffered_bytes(io::_BodyIO)::Int
    return max(io.filled - io.next_index + 1, 0)
end

function _fill_bodyio!(io::_BodyIO)::Int
    (@atomic :acquire io.closed) && return 0
    (@atomic :acquire io.saw_eof) && return 0
    io.next_index = 1
    n = body_read!(io.body, io.buf)
    io.filled = n
    if n == 0
        @atomic :release io.saw_eof = true
    end
    return n
end

function Base.isopen(io::_BodyIO)::Bool
    return !(@atomic :acquire io.closed)
end

function Base.bytesavailable(io::_BodyIO)::Int
    return _buffered_bytes(io)
end

function Base.eof(io::_BodyIO)::Bool
    _buffered_bytes(io) > 0 && return false
    (@atomic :acquire io.closed) && return true
    (@atomic :acquire io.saw_eof) && return true
    return _fill_bodyio!(io) == 0
end

function Base.read(io::_BodyIO, ::Type{UInt8})::UInt8
    eof(io) && throw(EOFError())
    b = io.buf[io.next_index]
    io.next_index += 1
    return b
end

function Base.readbytes!(io::_BodyIO, dst::Vector{UInt8}, nb::Integer=length(dst))::Int
    target = Int(nb)
    target < 0 && throw(ArgumentError("nb must be >= 0"))
    target = min(target, length(dst))
    total = 0
    while total < target
        available = _buffered_bytes(io)
        if available == 0
            _fill_bodyio!(io) == 0 && break
            available = _buffered_bytes(io)
        end
        chunk = min(available, target - total)
        copyto!(dst, total + 1, io.buf, io.next_index, chunk)
        io.next_index += chunk
        total += chunk
    end
    return total
end

function Base.unsafe_read(io::_BodyIO, ptr::Ptr{UInt8}, nbytes::UInt)
    remaining = Int(nbytes)
    offset = 0
    buf = io.buf
    while remaining > 0
        available = _buffered_bytes(io)
        if available == 0
            _fill_bodyio!(io) == 0 && throw(EOFError())
            available = _buffered_bytes(io)
        end
        chunk = min(available, remaining)
        GC.@preserve buf begin
            unsafe_copyto!(ptr + offset, pointer(buf, io.next_index), chunk)
        end
        io.next_index += chunk
        offset += chunk
        remaining -= chunk
    end
    return nothing
end

function Base.close(io::_BodyIO)
    if !(@atomic :acquire io.closed)
        @atomic :release io.closed = true
        @atomic :release io.saw_eof = true
        io.next_index = 1
        io.filled = 0
        body_close!(io.body)
    end
    return nothing
end

function _response_body_reader(incoming::_IncomingResponse; decompress::Union{Nothing,Bool})::Tuple{IO,Union{Nothing,Task}}
    raw_stream = _BodyIO(incoming.rawbody)
    encoding = _response_content_encoding(incoming.head.headers, decompress)
    if encoding == :gzip
        return CodecZlib.GzipDecompressorStream(raw_stream), nothing
    elseif encoding == :deflate
        return CodecZlib.ZlibDecompressorStream(raw_stream), nothing
    end
    return raw_stream, nothing
end

function _with_response_reader(f::F, incoming::_IncomingResponse; decompress::Union{Nothing,Bool}) where {F}
    reader, _ = _response_body_reader(incoming; decompress=decompress)
    try
        return f(reader)
    finally
        try
            close(reader)
        catch
        end
    end
end

function _resolve_response_sink(response_stream, response_body)
    if response_stream !== nothing && response_body !== response_stream
        throw(ArgumentError("response_stream and response_body must reference the same sink"))
    end
    if response_body === nothing || response_body isa IO || response_body isa AbstractVector{UInt8}
        return response_body
    end
    throw(ArgumentError("unsupported response body sink $(typeof(response_body)); expected nothing, IO, or AbstractVector{UInt8}"))
end

function _consume_incoming_response!(
    incoming::_IncomingResponse,
    sink;
    decompress::Union{Nothing,Bool},
)::Tuple{Any,Int64}
    if !_should_decompress_response(incoming.head.headers, decompress)
        try
            if sink === nothing
                body = _read_all_response_bytes(incoming.rawbody; content_length_hint=incoming.head.content_length)
                return body, Int64(length(body))
            end
            if sink isa IO
                n = _copy_response_bytes!(sink::IO, incoming.rawbody)
                return nothing, n
            end
            n = _copy_response_bytes!(sink::AbstractVector{UInt8}, incoming.rawbody)
            if sink isa Vector{UInt8}
                return sink::Vector{UInt8}, n
            end
            return view(sink::AbstractVector{UInt8}, 1:Int(n)), n
        catch
            try
                body_close!(incoming.rawbody)
            catch
            end
            rethrow()
        end
    end
    return _with_response_reader(incoming; decompress=decompress) do reader
        if sink === nothing
            body = _read_all_response_bytes(reader)
            return body, Int64(length(body))
        end
        if sink isa IO
            n = _copy_response_bytes!(sink::IO, reader)
            return nothing, n
        end
        n = _copy_response_bytes!(sink::AbstractVector{UInt8}, reader)
        if sink isa Vector{UInt8}
            return sink::Vector{UInt8}, n
        end
        return view(sink::AbstractVector{UInt8}, 1:Int(n)), n
    end
end

function _add_header_value!(headers::Headers, key, value)
    key_s = String(key)
    if value isa AbstractVector && !(value isa AbstractString)
        for item in value
            appendheader(headers, key_s, String(item))
        end
        return nothing
    end
    appendheader(headers, key_s, String(value))
    return nothing
end

function _is_header_list_entry(x)::Bool
    x isa Pair && return true
    (x isa Tuple && length(x) == 2) && return true
    return false
end

function _is_headers_input(x)::Bool
    x === nothing && return true
    x isa Headers && return true
    x isa AbstractDict && return true
    if x isa AbstractVector
        for item in x
            _is_header_list_entry(item) || return false
        end
        return true
    end
    return false
end

function _normalize_headers_input(headers_input)::Headers
    headers_input === nothing && return Headers()
    headers_input isa Headers && return copy(headers_input)
    headers = Headers()
    if headers_input isa AbstractDict
        for (k, v) in pairs(headers_input)
            _add_header_value!(headers, k, v)
        end
        return headers
    end
    if headers_input isa AbstractVector
        for item in headers_input
            if item isa Pair
                pair = item::Pair
                _add_header_value!(headers, pair.first, pair.second)
                continue
            end
            if item isa Tuple && length(item) == 2
                tup = item::Tuple
                _add_header_value!(headers, tup[1], tup[2])
                continue
            end
            throw(ArgumentError("unsupported header entry type $(typeof(item)); expected Pair or 2-tuple"))
        end
        return headers
    end
    throw(ArgumentError("unsupported headers input type $(typeof(headers_input))"))
end

function _apply_default_accept_encoding!(headers::Headers, decompress::Union{Nothing,Bool})::Nothing
    decompress === false && return nothing
    hasheader(headers, "Accept-Encoding") && return nothing
    setheader(headers, "Accept-Encoding", "gzip, deflate")
    return nothing
end


function _method_upper(method::Union{AbstractString,Symbol})::String
    return uppercase(String(method))
end

@inline function _basic_auth_header(username::AbstractString, password::AbstractString)::String
    return "Basic " * base64encode(string(username, ":", password))
end

function _basic_auth_header(basicauth)::String
    if basicauth isa Tuple && length(basicauth) == 2
        return _basic_auth_header(String(basicauth[1]), String(basicauth[2]))
    end
    if basicauth isa Pair
        return _basic_auth_header(String(basicauth.first), String(basicauth.second))
    end
    throw(ArgumentError("basicauth must be `nothing`, `(username, password)`, or `username => password`"))
end

function _apply_request_authorization!(
    headers::Headers,
    basicauth,
    url_authorization::Union{Nothing,String},
)::Nothing
    hasheader(headers, "Authorization") && return nothing
    if basicauth !== nothing
        setheader(headers, "Authorization", _basic_auth_header(basicauth))
        return nothing
    end
    url_authorization === nothing || setheader(headers, "Authorization", url_authorization::String)
    return nothing
end

function _client_for_request(
    client::Union{Nothing,Client};
    connect_timeout::Real,
    require_ssl_verification::Bool,
)::Tuple{Client,Bool}
    connect_timeout >= 0 || throw(ArgumentError("connect_timeout must be >= 0"))
    if client !== nothing
        if !require_ssl_verification
            throw(ArgumentError("require_ssl_verification overrides are not supported when passing an explicit Client"))
        end
        return client::Client, false
    end
    if require_ssl_verification
        return _default_client!(), false
    end
    tls_config = require_ssl_verification ? nothing : TLS.Config(verify_peer=false)
    transport = Transport(
        tls_config=tls_config,
        proxy=ProxyFromEnvironment(),
        max_idle_per_host=1,
        max_idle_total=1,
        idle_timeout_ns=Int64(0),
    )
    return Client(transport=transport), true
end

function _validate_request_extra_kwargs(kwargs)
    for (k, v) in kwargs
        if k == :verbose || k == :canonicalize_headers || k == :logerrors || k == :observelayers
            continue
        end
        throw(ArgumentError("unsupported keyword argument: $k"))
    end
    return nothing
end

@inline function _request_deadline_ns(request::Request)::Int64
    ctx = request.context
    ctx === nothing && return Int64(0)
    return (ctx::RequestContext).deadline_ns
end

function _apply_conn_deadline!(conn::Conn, deadline_ns::Int64)
    if conn.secure
        conn.tls === nothing || TLS.set_deadline!(conn.tls::TLS.Conn, deadline_ns)
    else
        conn.tcp === nothing || TCP.set_deadline!(conn.tcp::TCP.Conn, deadline_ns)
    end
    return nothing
end

function _clear_conn_deadline!(conn::Conn)
    if conn.secure
        conn.tls === nothing || TLS.set_deadline!(conn.tls::TLS.Conn, Int64(0))
    else
        conn.tcp === nothing || TCP.set_deadline!(conn.tcp::TCP.Conn, Int64(0))
    end
    return nothing
end

@inline function _request_connect_phase_timeout_ns(base::HostResolvers.HostResolver, request::Request)::Int64
    return _min_nonzero_ns(base.timeout_ns, _request_connect_timeout_ns(request))
end

@inline function _request_connect_phase_deadline_ns(base::HostResolvers.HostResolver, request::Request)::Int64
    overall_deadline_ns = _min_nonzero_ns(base.deadline_ns, _request_deadline_ns(request))
    timeout_ns = _request_connect_phase_timeout_ns(base, request)
    return _phase_deadline_ns(timeout_ns, overall_deadline_ns)
end

function _request_connect_host_resolver(base::HostResolvers.HostResolver, request::Request)::HostResolvers.HostResolver
    timeout_ns = _request_connect_phase_timeout_ns(base, request)
    deadline_ns = _min_nonzero_ns(base.deadline_ns, _request_deadline_ns(request))
    if timeout_ns == base.timeout_ns && deadline_ns == base.deadline_ns
        return base
    end
    return HostResolvers.HostResolver(
        timeout_ns=timeout_ns,
        deadline_ns=deadline_ns,
        local_addr=base.local_addr,
        fallback_delay_ns=base.fallback_delay_ns,
        resolver=base.resolver,
        policy=base.policy,
    )
end


"""
    request(method, url::Union{AbstractString,URI}, headers=Pair{String,String}[], body=nothing; kwargs...)

High-level one-shot HTTP request API.

Keyword arguments:
- `basicauth`: optional basic-auth credentials supplied as
  `(username, password)` or `username => password`; explicit
  `Authorization` headers take precedence, and URL `userinfo` is only used as a
  fallback when neither is provided
- `retry`: overall toggle for high-level request retries; lower-level reused-connection transport retries still happen independently
- `retries`: maximum number of retry attempts after the initial request attempt
- `retry_non_idempotent`: allow automatic retries for methods like `POST`/`PATCH`; `PUT` and `DELETE` are already treated as idempotent
- `retry_if`: optional callback `(attempt, err, req, resp) -> Bool | nothing`; `true` forces a retry when the request body is replayable, `false` suppresses retry, and `nothing` defers to built-in retry rules
- `respect_retry_after`: honor server `Retry-After` on retryable `429`/`503` responses
- `retry_bucket`: `true` uses the request transport's default `RetryBucket`, `false` disables bucket coordination, and a custom `RetryBucket` overrides the transport default
- automatic retries only occur for replayable request bodies; built-in policy retries idempotent methods (`GET`, `HEAD`, `OPTIONS`, `TRACE`, `PUT`, `DELETE`) plus requests carrying `Idempotency-Key`/`X-Idempotency-Key`
- `status_exception`: throw `StatusError` for non-success responses
- `redirect`: follow redirects through `do!`
- `redirect_limit`: maximum number of redirects to follow for this call;
  `0` disables redirect following while still returning the redirect response
- `redirect_method`: override the method used for `301`/`302` redirects; pass
  `:same` to preserve the original method
- `forwardheaders`: whether original request headers are copied onto redirect
  follow-up requests
- request bodies may be passed positionally or, for convenience helpers like
  `post(url; body=...)`, via the `body` keyword; supported inputs include
  strings, byte vectors, `IO`, `Dict`/`NamedTuple` form fields, `HTTP.Form`,
  iterable chunks, and existing `HTTP.AbstractBody` values
- `proxy`: explicit proxy override for this call; pass a proxy URL string, a
  `ProxyConfig`, or `nothing` to force direct connections
- `cookies`: `true` to use the effective cookie jar, `false` to disable cookie
  send/store for this call, or a dictionary of extra cookie name/value pairs to
  append to jar-derived cookies
- `cookiejar`: optional cookie jar override for this call; explicit clients
  default to `client.cookiejar`, while implicit convenience calls default to the
  shared `HTTP.COOKIEJAR`
- `query`: optional query string or key/value collection appended to the URL
- `response_body`: optional sink `IO` or byte buffer written with the final response body
- `decompress`: `nothing`/`true` auto-decompress gzip and deflate responses, `false` leaves wire bytes untouched
- `sse_callback`: callback receiving `(event)` or `(stream, event)` for
  successful SSE responses
- `verbose`: `true`/`1` prints compact client progress logs, `2` adds detailed
  request/response dumps with body previews, and `3` includes full captured
  bodies
- `verbose_body_nbytes`: maximum request/response body bytes shown by
  `verbose=2`; ignored by `verbose=3`
- `verbose_io`: destination `IO` for verbose logs; defaults to `stderr`
- `client`: optional explicit `Client`; otherwise a default or ephemeral client
  is created
- `connect_timeout`: connection establishment timeout in seconds; currently
  enforced for implicit-client dialing and additionally tracked per request for
  lower layers
- `request_timeout`: overall request deadline in seconds
- `response_header_timeout`: maximum time to wait for response headers after
  the request has been sent
- `read_idle_timeout`: maximum time between inbound read progress events
- `write_idle_timeout`: maximum time between outbound write progress events
- `expect_continue_timeout`: how long to wait for a `100 Continue` response
  before sending the request body anyway; pass `0` to disable the wait
- `readtimeout`: deprecated alias for `read_idle_timeout`
- `require_ssl_verification`: disable certificate verification only for testing
- `protocol`: `:auto`, `:h1`, or `:h2`

The built-in retry policy is intentionally conservative: it retries transient
transport errors plus retryable `408`/`429`/`5xx` responses for replayable
requests, but does not automatically retry request read-timeout/deadline
failures.

Returns a high-level `Response`. When no response body sink is provided,
`response.body` is a fully materialized `Vector{UInt8}`. When `response_body`
is provided, the final `Response` contains either the filled buffer/view or
`nothing` for `IO` sinks.

Throws `ArgumentError` for unsupported inputs or invalid sink combinations,
`StatusError` when `status_exception=true` and the response status is considered
failing, plus any lower-level transport or protocol exception raised during the
request. Automatic retries only occur for replayable request bodies.
"""
function request(
    method::Union{AbstractString,Symbol},
    url::Union{AbstractString,URI},
    h=Pair{String,String}[],
    b=nothing;
    headers=h,
    body=b,
    basicauth=nothing,
    retry::Bool=true,
    retries::Integer=4,
    retry_non_idempotent::Bool=false,
    retry_if=nothing,
    respect_retry_after::Bool=true,
    retry_bucket::Union{Bool,RetryBucket}=true,
    status_exception::Bool=true,
    redirect::Bool=true,
    redirect_limit::Union{Nothing,Integer}=nothing,
    redirect_method=nothing,
    forwardheaders::Bool=true,
    proxy=_USE_TRANSPORT_PROXY,
    cookies=true,
    cookiejar::Union{Nothing,CookieJar}=nothing,
    query=nothing,
    response_stream=nothing,
    response_body=response_stream,
    decompress::Union{Nothing,Bool}=nothing,
    sse_callback=nothing,
    verbose=false,
    verbose_body_nbytes::Integer=_VERBOSE_DEFAULT_BODY_NBYTES,
    verbose_io::IO=stderr,
    client::Union{Nothing,Client}=nothing,
    connect_timeout::Real=0,
    request_timeout::Real=0,
    response_header_timeout::Real=0,
    read_idle_timeout::Real=0,
    write_idle_timeout::Real=0,
    expect_continue_timeout=nothing,
    readtimeout=nothing,
    require_ssl_verification::Bool=true,
    protocol::Symbol=:auto,
    kwargs...,
)
    _validate_request_extra_kwargs(kwargs)
    request_timeout_ns, timeout_config = _resolve_request_timeout_settings(
        ;
        request_timeout=request_timeout,
        connect_timeout=connect_timeout,
        response_header_timeout=response_header_timeout,
        read_idle_timeout=read_idle_timeout,
        write_idle_timeout=write_idle_timeout,
        expect_continue_timeout=expect_continue_timeout,
        readtimeout=readtimeout,
    )
    parsed = _parse_http_url(url; query=query)
    req_headers = _normalize_headers_input(headers)
    normalized_cookies = _normalize_cookies_input(cookies)
    sink = _resolve_response_sink(response_stream, response_body)
    sse_callback === nothing || sink === nothing || throw(ArgumentError("sse_callback cannot be combined with response_stream or response_body"))
    _apply_default_accept_encoding!(req_headers, decompress)
    _apply_request_authorization!(req_headers, basicauth, parsed.authorization)
    normalized_body = _normalize_body_input(body)
    if normalized_body.default_content_type !== nothing && !hasheader(req_headers, "Content-Type")
        setheader(req_headers, "Content-Type", normalized_body.default_content_type::String)
    end
    req = Request(
        _method_upper(method),
        parsed.target;
        headers=req_headers,
        body=normalized_body.body,
        host=parsed.address,
        content_length=normalized_body.content_length,
    )
    config = _verbose_config(; verbose=verbose, verbose_body_nbytes=verbose_body_nbytes, verbose_io=verbose_io)
    config === nothing || _set_request_context_verbose_config!(req.context, config)
    _apply_request_timeout_settings!(req.context, request_timeout_ns, timeout_config)
    req_client, owns_client = _client_for_request(client; connect_timeout=connect_timeout, require_ssl_verification=require_ssl_verification)
    retry_controller = _retry_controller(
        req_client;
        retry=retry,
        retries=retries,
        retry_non_idempotent=retry_non_idempotent,
        retry_if=retry_if,
        respect_retry_after=respect_retry_after,
        retry_bucket=retry_bucket,
    )
    client === nothing || proxy === _USE_TRANSPORT_PROXY || throw(ArgumentError("proxy override is not supported when passing an explicit Client"))
    proxy_config = _proxy_config_for_request(req_client, proxy)
    effective_cookiejar = _effective_cookiejar(client, cookiejar)
    incoming_response = nothing
    try
        incoming_response = _do_incoming!(
            req_client,
            parsed.address,
            req;
            secure=parsed.secure,
            server_name=parsed.server_name,
            protocol=protocol,
            redirect_policy=_redirect_policy(
                req_client;
                redirect_limit=redirect ? redirect_limit : 0,
                redirect_method=redirect_method,
                forwardheaders=forwardheaders,
            ),
            retry_controller=retry_controller,
            proxy_config=proxy_config,
            cookies=normalized_cookies,
            cookiejar=effective_cookiejar,
        )
        incoming = incoming_response::_IncomingResponse
        resolved_request = incoming.head.request === nothing ? req : incoming.head.request::Request
        if sse_callback !== nothing
            sse_response = _finalize_request_response(incoming, nobody, Int64(0), resolved_request, parsed.url)
            if !_status_throws(sse_response)
                _consume_incoming_sse!(incoming, sse_response, sse_callback::Function; decompress=decompress)
                return sse_response
            end
        end
        final_body, final_length = _consume_incoming_response!(incoming, sink; decompress=decompress)
        response = _finalize_request_response(incoming, final_body, final_length, resolved_request, parsed.url)
        status_exception && _status_throws(response) && throw(StatusError(response))
        return response
    finally
        owns_client && close(req_client)
    end
end

function _finalize_request_response(
    incoming::_IncomingResponse,
    body,
    body_length::Int64,
    resolved_request::Request,
    request_url::String,
)::Response
    return _response_nocopy_public(
        incoming.head.status,
        incoming.head.reason,
        incoming.head.headers,
        incoming.head.trailers,
        body,
        body_length,
        incoming.head.proto_major,
        incoming.head.proto_minor,
        incoming.head.close,
        resolved_request,
        incoming.head.request_url === nothing ? request_url : (incoming.head.request_url::String),
        incoming.head.previous,
        incoming.head.redirect_count,
    )
end

function _split_headers_body_args(args::Tuple)
    if isempty(args)
        return Pair{String,String}[], nothing
    end
    if length(args) == 1
        arg = args[1]
        if _is_headers_input(arg)
            return arg, nothing
        end
        return Pair{String,String}[], arg
    end
    if length(args) == 2
        return args[1], args[2]
    end
    throw(ArgumentError("expected at most two positional arguments after URL: headers and body"))
end

"""`GET` convenience wrapper around `request`."""
function get(url::Union{AbstractString,URI}, headers=Pair{String,String}[]; kwargs...)
    return request("GET", url, headers, nothing; kwargs...)
end

"""`HEAD` convenience wrapper around `request`."""
function head(url::Union{AbstractString,URI}, headers=Pair{String,String}[]; kwargs...)
    return request("HEAD", url, headers, nothing; kwargs...)
end

"""`POST` convenience wrapper around `request`."""
function post(url::Union{AbstractString,URI}, args...; kwargs...)
    headers, body = _split_headers_body_args(args)
    return request("POST", url, headers, body; kwargs...)
end

"""`PUT` convenience wrapper around `request`."""
function put(url::Union{AbstractString,URI}, args...; kwargs...)
    headers, body = _split_headers_body_args(args)
    return request("PUT", url, headers, body; kwargs...)
end

"""`PATCH` convenience wrapper around `request`."""
function patch(url::Union{AbstractString,URI}, args...; kwargs...)
    headers, body = _split_headers_body_args(args)
    return request("PATCH", url, headers, body; kwargs...)
end

"""`DELETE` convenience wrapper around `request`."""
function delete(url::Union{AbstractString,URI}, args...; kwargs...)
    headers, body = _split_headers_body_args(args)
    return request("DELETE", url, headers, body; kwargs...)
end

"""`OPTIONS` convenience wrapper around `request`."""
function options(url::Union{AbstractString,URI}, headers=Pair{String,String}[]; kwargs...)
    return request("OPTIONS", url, headers, nothing; kwargs...)
end
