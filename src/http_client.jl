# High-level HTTP client orchestration, HTTP/2 integration, cookies, response sinks, and convenience APIs.

"""
    Client(; ...)

High-level HTTP client with transport pooling, redirect policy, cookies, and
optional HTTP/2. Also acts as a configuration container so that defaults set
once on the client (headers, query parameters, timeouts, basic auth) apply
to every request issued through it unless the per-call `request`/`get`/`post`
keywords override them.

Keyword arguments:
- `transport`: reusable lower-level HTTP/1 transport/pool implementation
- `check_redirect`: optional callback deciding whether a redirect should be
  followed
- `cookiejar`: cookie jar implementation, or `nothing` to disable cookies
- `max_redirects`: maximum redirect hops before failing
- `prefer_http2`: whether secure requests should try HTTP/2 when available
- `default_headers`: headers applied to every request issued through this
  client; per-call `headers` are appended on top, and per-call values for the
  same name take precedence
- `default_query`: query parameters appended to every request URL; per-call
  `query` overrides any keys it shares with the default
- `default_basicauth`: default basic-auth credentials applied unless the call
  passes `basicauth` or an explicit `Authorization` header
- `connect_timeout`, `request_timeout`, `response_header_timeout`,
  `read_idle_timeout`, `write_idle_timeout`: defaults applied to every request
  unless the call passes the matching keyword. `0` disables.

Pass a `Client` with the `client` keyword to `request`, `get`, `open`, or the
other verb helpers when you want connection reuse and shared cookies across
many calls. The verb helpers also accept the client positionally
(`HTTP.get(client, url; ...)`). Close the client when you are finished; once
closed, subsequent calls that use it raise `ArgumentError`.
"""
mutable struct Client{CR}
    transport::Transport
    check_redirect::CR
    cookiejar::Union{Nothing,CookieJar}
    max_redirects::Int
    prefer_http2::Bool
    h2_lock::ReentrantLock
    h2_conns::Dict{String,Vector{H2Connection}}
    default_headers::Headers
    default_query::Union{Nothing,Vector{Pair{String,String}}}
    default_basicauth::Any
    default_connect_timeout::Float64
    default_request_timeout::Float64
    default_response_header_timeout::Float64
    default_read_idle_timeout::Float64
    default_write_idle_timeout::Float64
    @atomic closed::Bool
end

abstract type ClientEvent end

"""
    RequestEvent

Trace event emitted immediately before a high-level request attempt is sent.

Fields:
- `request`: request head/body metadata for the attempt
- `url`: absolute request URL for the attempt
- `attempt`: 1-based request attempt number
- `redirect_count`: number of redirects already followed before this attempt
- `protocol`: `:h1` or `:h2` for the selected wire protocol
"""
struct RequestEvent <: ClientEvent
    request::Request
    url::String
    attempt::Int
    redirect_count::Int
    protocol::Symbol
end

"""
    ResponseHeadEvent

Trace event emitted after response headers are available for a successful
request attempt and before the body is fully consumed.

Fields:
- `response`: response head metadata for the attempt
- `url`: absolute request URL for the attempt
- `attempt`: 1-based request attempt number
- `redirect_count`: number of redirects followed before this response
"""
struct ResponseHeadEvent <: ClientEvent
    response::Response
    url::String
    attempt::Int
    redirect_count::Int
end

"""
    RetryEvent

Trace event emitted when the high-level request path schedules another attempt.

Fields:
- `request`: request metadata that will be retried
- `url`: absolute request URL for the attempt being retried
- `attempt`: current 1-based attempt number
- `next_attempt`: next 1-based attempt number
- `redirect_count`: redirects already followed when the retry decision was made
- `delay_ns`: delay before the next attempt in nanoseconds
- `response`: retry-triggering response, or `nothing` for request-path failures
- `err`: retry-triggering exception, or `nothing` for response-based retries
"""
struct RetryEvent <: ClientEvent
    request::Request
    url::String
    attempt::Int
    next_attempt::Int
    redirect_count::Int
    delay_ns::Int64
    response::Union{Nothing,Response}
    err::Union{Nothing,Exception}
end

"""
    RedirectEvent

Trace event emitted when a redirect response is accepted and a follow-up request
is about to be issued.

Fields:
- `request`: original request metadata that produced the redirect response
- `response`: redirect response head
- `from_url`: original absolute request URL
- `to_url`: resolved redirect target URL
- `redirect_count`: 1-based redirect count after accepting this redirect
"""
struct RedirectEvent <: ClientEvent
    request::Request
    response::Response
    from_url::String
    to_url::String
    redirect_count::Int
end

"""
    DoneEvent

Trace event emitted when a high-level request call finishes, either with a
final response or an exception.

Fields:
- `response`: final response, or `nothing` if the request failed before one was produced
- `err`: terminal exception, or `nothing` when the request completed successfully
- `url`: absolute request URL for the overall call
"""
struct DoneEvent <: ClientEvent
    response::Union{Nothing,Response}
    err::Union{Nothing,Exception}
    url::String
end

@inline function _warn_ignored_client_compat_kw(name::AbstractString)::Nothing
    @warn "`$name` is accepted for compatibility but is no longer supported in the HTTP 2.0 client and has no effect" maxlog=1
    return nothing
end

@inline function _warn_unimplemented_client_compat_kw(name::AbstractString)::Nothing
    @warn "`$name` is accepted for compatibility but is not implemented yet in the HTTP 2.0 client" maxlog=1
    return nothing
end

function _handle_client_compat_kwargs(;
    copyheaders=nothing,
    pool=nothing,
    canonicalize_headers=nothing,
    detect_content_type=nothing,
    observelayers=nothing,
    retry_delays=nothing,
    retry_check=nothing,
    sslconfig=nothing,
    socket_type_tls=nothing,
    logerrors=nothing,
    logtag=nothing,
)::Nothing
    copyheaders === nothing || _warn_ignored_client_compat_kw("copyheaders")
    pool === nothing || _warn_ignored_client_compat_kw("pool")
    canonicalize_headers === nothing || _warn_ignored_client_compat_kw("canonicalize_headers")
    detect_content_type === nothing || _warn_ignored_client_compat_kw("detect_content_type")
    observelayers === nothing || _warn_ignored_client_compat_kw("observelayers")
    retry_delays === nothing || _warn_ignored_client_compat_kw("retry_delays")
    retry_check === nothing || _warn_ignored_client_compat_kw("retry_check")
    sslconfig === nothing || _warn_ignored_client_compat_kw("sslconfig")
    socket_type_tls === nothing || _warn_ignored_client_compat_kw("socket_type_tls")
    logerrors === nothing || logerrors === false || _warn_unimplemented_client_compat_kw("logerrors")
    logtag === nothing || _warn_unimplemented_client_compat_kw("logtag")
    return nothing
end

struct _VerboseTrace
    level::Int
end

struct _ComposedTrace{A,B}
    first::A
    second::B
end

@inline _emit_trace(::Nothing, event::ClientEvent) = nothing

@inline function _emit_trace(trace, event::ClientEvent)
    trace(event)
    return nothing
end

@inline function (trace::_ComposedTrace)(event::ClientEvent)
    trace.first(event)
    trace.second(event)
    return nothing
end

@inline function _normalize_verbose_level(verbose)::Int
    verbose === nothing && return 0
    verbose === false && return 0
    verbose === true && return 1
    verbose isa Integer || throw(ArgumentError("verbose must be Bool or an integer level 0-2"))
    level = Int(verbose)
    0 <= level <= 2 || throw(ArgumentError("verbose must be one of false, true, 0, 1, or 2"))
    return level
end

@inline function _wrap_request_trace(trace, verbose)
    level = _normalize_verbose_level(verbose)
    if level == 0
        return trace
    elseif trace === nothing
        return _VerboseTrace(level)
    end
    return _ComposedTrace(_VerboseTrace(level), trace)
end

@inline function _verbose_line!(msg::AbstractString)::Nothing
    println(stdout, "[http] ", msg)
    flush(stdout)
    return nothing
end

@inline function _verbose_block!(label::AbstractString, f)::Nothing
    println(stdout, "[http] ", label)
    f(stdout)
    flush(stdout)
    return nothing
end

function (trace::_VerboseTrace)(event::RequestEvent)::Nothing
    _verbose_line!(string("request attempt ", event.attempt, " ", event.request.method, " ", event.url, " via ", event.protocol))
    if trace.level >= 2
        _verbose_block!("request", io -> begin
            show(io, MIME"text/plain"(), event.request)
            write(io, '\n')
        end)
    end
    return nothing
end

function (trace::_VerboseTrace)(event::ResponseHeadEvent)::Nothing
    _verbose_line!(string("response attempt ", event.attempt, " ", event.response.status, " for ", event.url))
    if trace.level >= 2
        _verbose_block!("response", io -> begin
            show(io, MIME"text/plain"(), event.response)
            write(io, '\n')
        end)
    end
    return nothing
end

function (trace::_VerboseTrace)(event::RetryEvent)::Nothing
    detail = if event.err !== nothing
        sprint(showerror, event.err::Exception)
    elseif event.response !== nothing
        string("status ", (event.response::Response).status)
    else
        "retry"
    end
    _verbose_line!(string("retry ", event.attempt, " -> ", event.next_attempt, " after ", detail, " (", event.delay_ns, " ns)"))
    return nothing
end

function (trace::_VerboseTrace)(event::RedirectEvent)::Nothing
    _verbose_line!(string("redirect ", event.response.status, " ", event.from_url, " -> ", event.to_url))
    return nothing
end

function (trace::_VerboseTrace)(event::DoneEvent)::Nothing
    if event.err !== nothing
        _verbose_line!(string("done with error for ", event.url, ": ", sprint(showerror, event.err::Exception)))
    elseif event.response !== nothing
        _verbose_line!(string("done ", (event.response::Response).status, " for ", event.url))
    else
        _verbose_line!(string("done for ", event.url))
    end
    return nothing
end

function Client(;
    transport::Transport=Transport(proxy=ProxyFromEnvironment()),
    check_redirect=nothing,
    cookiejar::Union{Nothing,CookieJar}=CookieJar(),
    max_redirects::Integer=10,
    prefer_http2::Bool=true,
    default_headers=Pair{String,String}[],
    default_query=nothing,
    default_basicauth=nothing,
    connect_timeout::Real=0,
    request_timeout::Real=0,
    response_header_timeout::Real=0,
    read_idle_timeout::Real=0,
    write_idle_timeout::Real=0,
)
    max_redirects >= 0 || throw(ArgumentError("max_redirects must be >= 0"))
    return Client{typeof(check_redirect)}(
        transport,
        check_redirect,
        cookiejar,
        Int(max_redirects),
        prefer_http2,
        ReentrantLock(),
        Dict{String,Vector{H2Connection}}(),
        _normalize_headers_input(default_headers),
        _normalize_default_query(default_query),
        default_basicauth,
        Float64(connect_timeout),
        Float64(request_timeout),
        Float64(response_header_timeout),
        Float64(read_idle_timeout),
        Float64(write_idle_timeout),
        false,
    )
end

# Normalize default_query input into a Vector{Pair{String,String}} stored on the Client.
function _normalize_default_query(q)::Union{Nothing,Vector{Pair{String,String}}}
    q === nothing && return nothing
    pairs_out = Pair{String,String}[]
    if q isa AbstractDict
        for (k, v) in q
            push!(pairs_out, string(k) => string(v))
        end
    elseif q isa NamedTuple
        for (k, v) in pairs(q)
            push!(pairs_out, string(k) => string(v))
        end
    else
        for kv in q
            if kv isa Pair
                push!(pairs_out, string(kv.first) => string(kv.second))
            else
                throw(ArgumentError("default_query entries must be Pair{String,String}"))
            end
        end
    end
    isempty(pairs_out) && return nothing
    return pairs_out
end

struct _UseTransportProxy end

const _USE_TRANSPORT_PROXY = _UseTransportProxy()


function _redirect_policy(
    client::Client{CR},
    redirect_limit::Union{Nothing,Integer}=nothing,
    redirect_method=nothing,
    forwardheaders::Bool=true,
) where {CR}
    max_redirects = redirect_limit === nothing ? client.max_redirects : Int(redirect_limit)
    max_redirects >= 0 || throw(ArgumentError("redirect_limit must be >= 0"))
    callback = client.check_redirect
    method_override, preserve_method = _normalize_redirect_method_override(redirect_method)
    return _RedirectPolicy{CR}(callback, max_redirects, method_override, preserve_method, forwardheaders)
end

function _proxy_config_for_request(client::Client, proxy)::ProxyConfig
    proxy === _USE_TRANSPORT_PROXY && return client.transport.proxy
    return _normalize_proxy_config(proxy)
end

function Base.close(client::Client)
    @atomic :release client.closed = true
    close(client.transport)
    lock(client.h2_lock)
    try
        for (_, conns) in client.h2_conns
            for conn in conns
                @try_ignore begin
                    close(conn)
                end
            end
        end
        empty!(client.h2_conns)
    finally
        unlock(client.h2_lock)
    end
    return nothing
end

"""
    isopen(client::Client) -> Bool

Return `true` while `client` has not yet been closed.
"""
@inline Base.isopen(client::Client)::Bool = !(@atomic :acquire client.closed)

@inline function _check_client_open(client::Client)
    if @atomic :acquire client.closed
        throw(ArgumentError("HTTP.Client is closed"))
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
    secure::Bool,
    request::Union{Nothing,Request}=nothing,
    server_name::Union{Nothing,String}=nothing,
    allow_h1_alpn::Bool=false,
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
                    @try_ignore begin
                        close(existing::H2Connection)
                    end
                    continue
                end
            else
                # Atomically claim a pending slot so a concurrent acquirer
                # entering this loop doesn't see the same `existing` as
                # available before our caller calls `_register_stream!`.
                if _try_claim_h2_pending_slot!(existing::H2Connection)
                    return existing::H2Connection
                end
                # Lost the race for the last slot; fall through to evaluate
                # remaining cached connections (and ultimately open a new one).
            end
            i += 1
        end
        tls_cfg = if secure
            _make_tls_config_for_h2(
                client.transport.tls_config,
                address,
                server_name,
                tls_handshake_timeout_ns,
                allow_h1_alpn,
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
        elseif plan.mode == _ProxyPlanMode.HTTP_TUNNEL || _proxy_plan_is_socks(plan)
            proxy = plan.proxy
            proxy === nothing && throw(ProtocolError("proxy connection is missing proxy config"))
            tcp = _new_tcp_conn!(plan, address, connect_host_resolver, connect_deadline_ns)
            try
                connect_h2!(tcp, address; secure=secure, tls_config=tls_cfg, connect_deadline_ns=connect_deadline_ns)
            catch
                @try_ignore begin
                    TCP.close(tcp)
                end
                rethrow()
            end
        else
            throw(ArgumentError("HTTP/2 is not supported for proxy plan mode $(plan.mode)"))
        end
        # Claim a slot on the freshly opened connection up front so subsequent
        # acquirers that race in see this caller's pending request.
        _try_claim_h2_pending_slot!(conn::H2Connection)
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
                @try_ignore begin
                    close(conn)
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
    client.prefer_http2 || return false
    # If the user pinned the transport's ALPN list to a non-empty set that does
    # not include "h2", skip the h2 attempt entirely. Otherwise prefer_http2
    # would force a TLS handshake the user explicitly asked us not to attempt.
    cfg = client.transport.tls_config
    if cfg !== nothing && !isempty(cfg.alpn_protocols) && !in("h2", cfg.alpn_protocols)
        return false
    end
    return true
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
    manual::Vector{Cookie}=Cookie[],
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
    # Merge a caller-set `Cookie` request header with the managed cookies (this restores
    # the pre-2.0 behaviour, where a manual header was not silently dropped), but
    # de-duplicate by name so the wire header never carries the same name twice. Managed
    # cookies (the jar plus any `cookies=` dict) win; the manual header only contributes
    # names they do not already cover. This keeps a rotated jar cookie from being
    # shadowed by a stale manual one and preserves path-scoped same-name cookies held in
    # the jar. Use `cookies=false` to send a manual `Cookie` header verbatim.
    if !isempty(manual)
        managed = Set(c.name for c in merged)
        for c in manual
            if !(c.name in managed)
                push!(merged, c)
                push!(managed, c.name)
            end
        end
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
        get_request_context(request),
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
        get_request_context(request),
    )
end

@inline function _is_nonreplayable_body_error(err)::Bool
    err isa ProtocolError || return false
    return occursin("request body is not replayable for redirect", (err::ProtocolError).message)
end

function _copy_request_for_send(request::Request, allow_nonreplayable::Bool=false)::Request
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
    _do_incoming!(trace, client, address, request, false, nothing, :auto)

Send `request` with redirect handling and return the final low-level
`_IncomingResponse`.

This method preserves streaming bodies, so callers are responsible for draining
or closing `response.rawbody` or the wrapped public body derived from it.

`protocol` accepts `:auto`, `:h1`, or `:h2`. In `:auto` mode the client may try
HTTP/2 first for secure requests and fall back to HTTP/1 when negotiation says
that h2 is unavailable.
"""
function _do_incoming!(
    trace,
    client::Client,
    address::AbstractString,
    request::Request,
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
    previous_response = nothing
    retry_attempt = 1
    retry_token = nothing
    for redirect_count in 0:redirect_policy.max_redirects
        while true
            send_request = _copy_request_for_send(current_request, retry_attempt == 1)
            request_url = _request_url(current_secure, current_address, current_request.target)
            proxy_plan = _proxy_plan(proxy_config, current_secure, current_address)
            use_h2 = _use_h2(client, current_secure, protocol) && proxy_plan.mode != _ProxyPlanMode.HTTP_FORWARD
            _emit_trace(trace, RequestEvent(send_request, request_url, retry_attempt, redirect_count, use_h2 ? :h2 : :h1))
            host, path = _host_path_from_request(current_address, current_request)
            manual_cookies = cookies === false ? Cookie[] : Cookies.readcookies(send_request.headers, "")
            cookie_value = _cookie_header(cookiejar, cookies, current_secure, host, path, manual_cookies)
            cookie_value === nothing || setheader(send_request.headers, "Cookie", cookie_value)
            response = try
                if use_h2
                    conn = nothing
                    try
                        conn = _acquire_h2_conn!(
                            client,
                            proxy_plan,
                            current_address,
                            current_secure,
                            send_request,
                            current_server_name,
                            protocol == :auto,
                        )
                        _h2_roundtrip_incoming!(conn::H2Connection, send_request; pending_slot_claimed=true)
                    catch err
                        _drop_h2_conn!(client, proxy_plan, conn)
                        if protocol == :auto && _should_fallback_h2_to_h1(err)
                            send_request = _copy_request_for_send(current_request, retry_attempt == 1)
                            _roundtrip_incoming!(
                                client.transport,
                                current_address,
                                send_request,
                                current_secure,
                                current_server_name,
                                proxy_config,
                            )
                        else
                            rethrow(err)
                        end
                    end
                else
                    _roundtrip_incoming!(
                        client.transport,
                        current_address,
                        send_request,
                        current_secure,
                        current_server_name,
                        proxy_config,
                    )
                end
            catch err
                if retry_controller !== nothing && retry_controller.bucket !== nothing && retry_token !== nothing
                    release(retry_controller.bucket::RetryBucket, retry_token::RetryToken, _RETRY_BUCKET_ACQUIRE_COST)
                end
                retry_token = nothing
                if retry_controller !== nothing
                    if _should_retry_request_attempt(retry_controller, retry_attempt, current_request, RequestRetryError(err::Exception), nothing)
                        scheduled, next_token, delay_ns = _arm_request_retry!(retry_controller, current_address, current_request, retry_attempt, nothing)
                        if scheduled
                            _emit_trace(trace, RetryEvent(current_request, request_url, retry_attempt, retry_attempt + 1, redirect_count, delay_ns, nothing, err::Exception))
                            get_request_context(current_request)[:retryattempt] = retry_attempt
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
            _store_set_cookies!(cookiejar, cookies, current_secure, host, path, response.head.headers)
            status_response = _retry_policy_response(response, current_request)
            _emit_trace(trace, ResponseHeadEvent(status_response, request_url, retry_attempt, redirect_count))
            if retry_controller !== nothing && retry_controller.bucket !== nothing && retry_token !== nothing
                release(retry_controller.bucket::RetryBucket, retry_token::RetryToken, _retry_bucket_failure_cost(status_response.status))
            end
            retry_token = nothing
            if retry_controller !== nothing
                should_retry = try
                    _should_retry_request_attempt(retry_controller, retry_attempt, current_request, nothing, status_response)
                catch
                    @try_ignore begin
                        body_close!(response.rawbody)
                    end
                    rethrow()
                end
                if should_retry
                    scheduled, next_token, delay_ns = _arm_request_retry!(retry_controller, current_address, current_request, retry_attempt, status_response)
                    if scheduled
                        _emit_trace(trace, RetryEvent(current_request, request_url, retry_attempt, retry_attempt + 1, redirect_count, delay_ns, status_response, nothing))
                        get_request_context(current_request)[:retryattempt] = retry_attempt
                        retry_attempt += 1
                        retry_token = next_token
                        @try_ignore begin
                            body_close!(response.rawbody)
                        end
                        continue
                    end
                end
            end
            if !_is_redirect_status(response.head.status)
                return response
            end
            # From here on, resolve and validate the next request in a redirect chain.
            location = header(response.head.headers, "Location", nothing)
            (location === nothing || isempty(location::String)) && return response
            redirect_policy.max_redirects == 0 && return response
            redirect_count == redirect_policy.max_redirects && throw(TooManyRedirectsError(redirect_policy.max_redirects, _streaming_response(response)))
            if !_call_check_redirect(redirect_policy.check_redirect, _streaming_response(response), current_request, location)
                return response
            end
            next_method = _rewrite_method_for_redirect(current_request.method, response.head.status, redirect_policy)
            if _redirect_reuses_request_body(next_method) && !_redirect_body_replayable(current_request)
                return response
            end
            previous_response = _streaming_response(response)
            body_close!(response.rawbody)
            previous_secure = current_secure
            previous_address = current_address
            previous_target = current_request.target
            next_address, next_secure, next_target = _resolve_redirect_target(current_address, current_secure, location, current_request.target)
            _emit_trace(
                trace,
                RedirectEvent(
                    current_request,
                    previous_response,
                    request_url,
                    _request_url(next_secure, next_address, next_target),
                    redirect_count + 1,
                ),
            )
            current_address = next_address
            current_secure = next_secure
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
    context::Union{Nothing,RequestContext}=nothing,
)
    _check_client_open(client)
    if context !== nothing
        # Replace the request's context so cancellation/deadline writes propagate.
        request = _request_with_context(request, context::RequestContext)
    end
    start_ns = Int64(time_ns())
    deadline_ns = _request_deadline_ns(request)
    timeout_ns = deadline_ns > 0 ? max(Int64(0), deadline_ns - start_ns) : Int64(0)
    try
        normalized_cookies = _normalize_cookies_input(cookies)
        policy = _redirect_policy(client, redirect_limit, redirect_method, forwardheaders)
        proxy_config = _proxy_config_for_request(client, proxy)
        effective_cookiejar = _effective_cookiejar(client, cookiejar)
        if protocol === :h1
            incoming = _do_incoming!(
                nothing,
                client,
                address,
                request,
                secure,
                server_name,
                :h1,
                policy,
                nothing,
                proxy_config,
                normalized_cookies,
                effective_cookiejar,
            )
            return _streaming_response(incoming::_IncomingResponse{H1Body})
        elseif protocol === :h2
            incoming = _do_incoming!(
                nothing,
                client,
                address,
                request,
                secure,
                server_name,
                :h2,
                policy,
                nothing,
                proxy_config,
                normalized_cookies,
                effective_cookiejar,
            )
            return _streaming_response(incoming::_IncomingResponse{H2Body})
        elseif protocol === :auto
            incoming = _do_incoming!(
                nothing,
                client,
                address,
                request,
                secure,
                server_name,
                :auto,
                policy,
                nothing,
                proxy_config,
                normalized_cookies,
                effective_cookiejar,
            )
            return _streaming_response(incoming::Union{_IncomingResponse{H1Body},_IncomingResponse{H2Body}})
        end
        throw(ArgumentError("protocol must be :auto, :h1, or :h2"))
    catch err
        if !(err isa CanceledError)
            req_ctx = get_request_context(request)
            if canceled(req_ctx)
                msg = req_ctx.cancel_message === nothing ? "request canceled" : req_ctx.cancel_message::String
                throw(CanceledError(msg))
            end
        end
        elapsed_ns = Int64(time_ns()) - start_ns
        wrapped = _wrap_client_transport_error(err, "request", timeout_ns, elapsed_ns)
        wrapped === err ? rethrow() : throw(wrapped)
    end
end

import Base: get, get!

"""
    get!(client, address, target; secure=false, protocol=:auto)

Convenience GET request using an existing `Client`.

Returns the same low-level `Response` shape as `do!`.
"""
function get!(client::Client, address::AbstractString, target::AbstractString; secure::Bool=false, protocol::Symbol=:auto, kwargs...)
    request = Request("GET", target; host=String(address), body=EmptyBody(), content_length=0)
    return do!(client, address, request; secure=secure, protocol=protocol, kwargs...)
end

"""
    StatusError

Raised when `status_exception=true` and the response status indicates failure.

Fields:

- `status::Int16` — the response status code (mirrors `response.status` for
  convenience so catch sites can write `err.status` instead of
  `err.response.status`).
- `response::Response` — the full response that triggered the error.
"""
struct StatusError <: HTTPError
    status::Int16
    response::Response
end

StatusError(response::Response) = StatusError(response.status, response)

function Base.showerror(io::IO, err::StatusError)
    resp = err.response
    print(io, "http status error: ", err.status, " for ", resp.request.method, " ", resp.url)
    retries = retry_attempts(resp)
    retries > 0 && print(io, " (after ", retries, retries == 1 ? " retry" : " retries", ")")
    return nothing
end

"""
    retry_attempts(x) -> Int

Number of automatic retries the client performed for a request, `0` when the
first attempt was the only one. Accepts the `Request` or a client `Response`
(which consults its originating request).

The count lives in the request's context under the `:retryattempt` key — the
same location HTTP.jl 1.x used — so `get(req.context, :retryattempt, 0)`
continues to work for migrated code.
"""
retry_attempts(request::Request)::Int = Int(get(get_request_context(request), :retryattempt, 0))

function retry_attempts(response::Response)::Int
    request = response.request
    return request === nothing ? 0 : retry_attempts(request::Request)
end

"""
    TooManyRedirectsError

Raised when redirect following is enabled and the client exceeds the configured
redirect limit. The final redirect response is attached for inspection.
"""
struct TooManyRedirectsError <: HTTPError
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
const _DEFAULT_CLIENT = Ref{Union{Nothing,Client{Nothing}}}(nothing)
const COOKIEJAR = CookieJar()

function _default_client!()::Client{Nothing}
    lock(_DEFAULT_CLIENT_LOCK)
    try
        existing = _DEFAULT_CLIENT[]
        existing === nothing || return existing
        created = Client()
        _DEFAULT_CLIENT[] = created
        return created
    finally
        unlock(_DEFAULT_CLIENT_LOCK)
    end
end

close_idle_connections!(client::Client) = close_idle_connections!(client.transport)

function close_idle_connections!()
    lock(_DEFAULT_CLIENT_LOCK)
    client = try
        _DEFAULT_CLIENT[]
    finally
        unlock(_DEFAULT_CLIENT_LOCK)
    end
    client === nothing && return nothing
    return close_idle_connections!(client.transport)
end

function _status_throws(resp::Response)::Bool
    return resp.status >= 300 && !_is_redirect_status(resp.status)
end

function _read_all_response_bytes(io::IO, limit::Int=0)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 8192)
    total = 0
    while true
        n = readbytes!(io, buf, length(buf))
        n == 0 && return out
        total += n
        limit > 0 && total > limit && throw(DecompressionLimitError(limit))
        append!(out, @view(buf[1:n]))
    end
end

const _MAX_EAGER_RESPONSE_PREALLOC = Int64(1 << 20)

function _read_all_response_bytes(body::AbstractBody, content_length_hint::Int64=Int64(-1))::Vector{UInt8}
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

function _copy_response_bytes!(dest::IO, io::IO, limit::Int=0)::Int64
    buf = Vector{UInt8}(undef, 8192)
    total = Int64(0)
    while true
        n = readbytes!(io, buf, length(buf))
        n == 0 && return total
        total += n
        limit > 0 && total > limit && throw(DecompressionLimitError(limit))
        write(dest, view(buf, 1:n))
    end
end

function _copy_response_bytes!(dest::AbstractVector{UInt8}, io::IO, limit::Int=0)::Int64
    buf = Vector{UInt8}(undef, 8192)
    total = 0
    capacity = length(dest)
    while true
        n = readbytes!(io, buf, length(buf))
        n == 0 && break
        needed = total + n
        limit > 0 && needed > limit && throw(DecompressionLimitError(limit))
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

@inline function _status_has_no_response_body(status::Integer)::Bool
    return (100 <= status < 200) || status == 204 || status == 304
end

@inline function _incoming_response_has_no_body(incoming::_IncomingResponse)::Bool
    return _status_has_no_response_body(incoming.head.status) ||
        incoming.head.content_length == 0 ||
        incoming.rawbody isa EmptyBody
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
        @try_ignore begin
            body_close!(body)
        end
        @try_ignore begin
            close(stream)
        end
    end
    return nothing
end

# IO adapter used when callers ask for streaming response bodies as ordinary IO.
mutable struct _BodyIO{B<:AbstractBody} <: IO
    body::B
    buf::Vector{UInt8}
    next_index::Int
    filled::Int
    @atomic saw_eof::Bool
    @atomic closed::Bool
end

function _BodyIO(body::B, buffer_bytes::Integer=8192) where {B<:AbstractBody}
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

function Base.readavailable(io::_BodyIO)::Vector{UInt8}
    available = _buffered_bytes(io)
    if available == 0
        _fill_bodyio!(io)
        available = _buffered_bytes(io)
    end
    available == 0 && return UInt8[]
    out = io.buf[io.next_index:(io.next_index + available - 1)]
    io.next_index += available
    return out
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

function Base.read(io::_BodyIO)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 8192)
    while true
        n = readbytes!(io, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    return out
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

"""
    DecompressionLimitError(limit)

Thrown when an automatically decompressed response body exceeds the
`max_decompressed_size` byte limit passed to the request. Guards against
decompression bombs — small compressed payloads that inflate to exhaust memory.
"""
struct DecompressionLimitError <: Exception
    limit::Int
end

function Base.showerror(io::IO, err::DecompressionLimitError)
    print(io, "DecompressionLimitError: decompressed response body exceeded max_decompressed_size = ", err.limit, " bytes")
    return nothing
end

function _response_body_reader(incoming::_IncomingResponse, decompress::Union{Nothing,Bool})::Tuple{IO,Union{Nothing,Task}}
    raw_stream = _BodyIO(incoming.rawbody)
    encoding = _response_content_encoding(incoming.head.headers, decompress)
    if encoding == :gzip
        return CodecZlib.GzipDecompressorStream(raw_stream), nothing
    elseif encoding == :deflate
        return CodecZlib.ZlibDecompressorStream(raw_stream), nothing
    end
    return raw_stream, nothing
end

function _with_response_reader(f::F, incoming::_IncomingResponse, decompress::Union{Nothing,Bool}) where {F}
    reader, _ = _response_body_reader(incoming, decompress)
    try
        return f(reader)
    finally
        @try_ignore begin
            close(reader)
        end
    end
end

function _resolve_response_sink(response_stream)
    if response_stream === nothing || response_stream isa IO || response_stream isa AbstractVector{UInt8}
        return response_stream
    end
    throw(ArgumentError("unsupported response stream sink $(typeof(response_stream)); expected nothing, IO, or AbstractVector{UInt8}"))
end

function _consume_incoming_response!(
    incoming::_IncomingResponse,
    sink,
    decompress::Union{Nothing,Bool},
    max_decompressed_size::Int=0,
)::Tuple{Any,Int64}
    if _incoming_response_has_no_body(incoming) || !_should_decompress_response(incoming.head.headers, decompress)
        try
            if sink === nothing
                body = _read_all_response_bytes(incoming.rawbody, incoming.head.content_length)
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
            @try_ignore begin
                body_close!(incoming.rawbody)
            end
            rethrow()
        end
    end
    return _with_response_reader(incoming, decompress) do reader
        if sink === nothing
            body = _read_all_response_bytes(reader, max_decompressed_size)
            return body, Int64(length(body))
        end
        if sink isa IO
            n = _copy_response_bytes!(sink::IO, reader, max_decompressed_size)
            return nothing, n
        end
        n = _copy_response_bytes!(sink::AbstractVector{UInt8}, reader, max_decompressed_size)
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

const DEFAULT_USER_AGENT = "HTTP.jl/" * string(VERSION)

function _apply_default_user_agent!(headers::Headers)::Nothing
    hasheader(headers, "User-Agent") && return nothing
    setheader(headers, "User-Agent", DEFAULT_USER_AGENT)
    return nothing
end


function _method_upper(method::Union{AbstractString,Symbol})::String
    return uppercase(String(method))
end

@inline function _basic_auth_header(username::AbstractString, password::AbstractString)::String
    return "Basic " * _base64encode(string(username, ":", password))
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
    client::Client,
    connect_timeout::Real,
    require_ssl_verification::Bool,
)
    connect_timeout >= 0 || throw(ArgumentError("connect_timeout must be >= 0"))
    if !require_ssl_verification
        throw(ArgumentError("require_ssl_verification overrides are not supported when passing an explicit Client"))
    end
    return client, false
end

function _client_for_request(
    ::Nothing,
    connect_timeout::Real,
    require_ssl_verification::Bool,
)
    connect_timeout >= 0 || throw(ArgumentError("connect_timeout must be >= 0"))
    if require_ssl_verification
        return _default_client!(), false
    end
    tls_config = TLS.Config(
        nothing,
        false,
        false,
        TLS.ClientAuthMode.NoClientCert,
        nothing,
        nothing,
        nothing,
        nothing,
        String[],
        UInt16[],
        Int64(0),
        TLS.TLS1_2_VERSION,
        nothing,
        false,
        64,
    )
    transport = Transport(
        tls_config=tls_config,
        proxy=ProxyFromEnvironment(),
        max_idle_per_host=1,
        max_idle_total=1,
        idle_timeout_ns=Int64(0),
    )
    return Client(transport=transport), true
end

@inline function _request_deadline_ns(request::Request)::Int64
    return get_request_context(request).deadline_ns
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

@inline function _request_connect_phase_timeout_ns(base::_TransportHostResolver, request::Request)::Int64
    return _min_nonzero_ns(base.timeout_ns, _request_connect_timeout_ns(request))
end

@inline function _request_connect_phase_deadline_ns(base::_TransportHostResolver, request::Request)::Int64
    overall_deadline_ns = _min_nonzero_ns(base.deadline_ns, _request_deadline_ns(request))
    timeout_ns = _request_connect_phase_timeout_ns(base, request)
    return _phase_deadline_ns(timeout_ns, overall_deadline_ns)
end

function _request_connect_host_resolver(base::_TransportHostResolver, request::Request)::_TransportHostResolver
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

# --- Client default merging ---------------------------------------------------

"""
Apply `client.default_headers` to `req_headers` for every header key not already
set by the per-call headers. Per-call values take precedence over defaults.
"""
function _apply_client_default_headers!(req_headers::Headers, client::Union{Nothing,Client})
    client === nothing && return req_headers
    defaults = client.default_headers
    isempty(defaults.entries) && return req_headers
    for entry in defaults.entries
        key = first(entry)
        hasheader(req_headers, key) && continue
        setheader(req_headers, key, last(entry))
    end
    return req_headers
end

"""
Merge `client.default_query` with the per-call `query`. Per-call query takes
precedence — keys it provides override defaults of the same name. Returns a
merged query, or the original `query` when the client has no default query.
"""
function _merge_client_default_query(client::Union{Nothing,Client}, query)
    client === nothing && return query
    defaults = client.default_query
    defaults === nothing && return query
    if query === nothing
        return defaults
    end
    overrides_keys = Set{String}()
    overrides_pairs = Pair{String,String}[]
    if query isa AbstractDict
        for (k, v) in query
            sk = string(k)
            push!(overrides_keys, sk)
            push!(overrides_pairs, sk => string(v))
        end
    elseif query isa NamedTuple
        for (k, v) in pairs(query)
            sk = string(k)
            push!(overrides_keys, sk)
            push!(overrides_pairs, sk => string(v))
        end
    elseif query isa AbstractVector
        for kv in query
            kv isa Pair || throw(ArgumentError("query entries must be Pair{String,String}"))
            sk = string(kv.first)
            push!(overrides_keys, sk)
            push!(overrides_pairs, sk => string(kv.second))
        end
    else
        return query
    end
    merged = Pair{String,String}[]
    for kv in defaults
        kv.first in overrides_keys || push!(merged, kv)
    end
    append!(merged, overrides_pairs)
    return merged
end

"""
For timeout kwargs left at `0`, fall back to the client's default for the named field.
"""
@inline function _client_default_timeout(client::Union{Nothing,Client}, value::Real, field::Symbol)
    client === nothing && return value
    value > 0 && return value
    return getfield(client, field)
end


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
    decompress::Union{Nothing,Bool}=nothing,
    max_decompressed_size::Integer=0,
    sse_callback=nothing,
    client::Union{Nothing,Client}=nothing,
    context::Union{Nothing,RequestContext}=nothing,
    connect_timeout::Real=30,
    request_timeout::Real=0,
    response_header_timeout::Real=0,
    read_idle_timeout::Real=0,
    write_idle_timeout::Real=0,
    expect_continue_timeout=nothing,
    readtimeout=nothing,
    copyheaders=nothing,
    pool=nothing,
    canonicalize_headers=nothing,
    detect_content_type=nothing,
    observelayers=nothing,
    retry_delays=nothing,
    retry_check=nothing,
    sslconfig=nothing,
    socket_type_tls=nothing,
    logerrors=nothing,
    logtag=nothing,
    trace=nothing,
    verbose=nothing,
    require_ssl_verification::Bool=true,
    protocol::Symbol=:auto
)
    client === nothing || _check_client_open(client)
    trace = if verbose === false || verbose === nothing
        trace
    else
        _wrap_request_trace(trace, verbose)
    end
    final_response = nothing
    final_error = nothing
    request_url = nothing
    request_timeout_ns = Int64(0)
    request_start_ns = Int64(time_ns())
    req_context = context === nothing ? RequestContext() : context::RequestContext
    try
        _handle_client_compat_kwargs(
            copyheaders=copyheaders,
            pool=pool,
            canonicalize_headers=canonicalize_headers,
            detect_content_type=detect_content_type,
            observelayers=observelayers,
            retry_delays=retry_delays,
            retry_check=retry_check,
            sslconfig=sslconfig,
            socket_type_tls=socket_type_tls,
            logerrors=logerrors,
            logtag=logtag,
        )
        # Merge per-call values with client defaults (per-call wins)
        connect_timeout = _client_default_timeout(client, connect_timeout, :default_connect_timeout)
        request_timeout = _client_default_timeout(client, request_timeout, :default_request_timeout)
        response_header_timeout = _client_default_timeout(client, response_header_timeout, :default_response_header_timeout)
        read_idle_timeout = _client_default_timeout(client, read_idle_timeout, :default_read_idle_timeout)
        write_idle_timeout = _client_default_timeout(client, write_idle_timeout, :default_write_idle_timeout)
        if basicauth === nothing && client !== nothing
            basicauth = client.default_basicauth
        end
        request_timeout_ns, timeout_config = _resolve_request_timeout_settings(
            request_timeout,
            connect_timeout,
            response_header_timeout,
            read_idle_timeout,
            write_idle_timeout,
            expect_continue_timeout,
            readtimeout,
        )
        merged_query = _merge_client_default_query(client, query)
        parsed = _parse_http_url(url, merged_query)
        request_url = parsed.url
        req_headers = _normalize_headers_input(headers)
        _apply_client_default_headers!(req_headers, client)
        normalized_cookies = _normalize_cookies_input(cookies)
        sink = _resolve_response_sink(response_stream)
        sse_callback === nothing || sink === nothing || throw(ArgumentError("sse_callback cannot be combined with response_stream"))
        _apply_default_accept_encoding!(req_headers, decompress)
        _apply_default_user_agent!(req_headers)
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
            context=req_context,
        )
        _apply_request_timeout_settings!(get_request_context(req), request_timeout_ns, timeout_config)
        req_client, owns_client = _client_for_request(client, connect_timeout, require_ssl_verification)
        try
            retry_controller = _retry_controller(req_client, retry, retries, retry_non_idempotent, retry_if, respect_retry_after, retry_bucket)
            client === nothing || proxy === _USE_TRANSPORT_PROXY || throw(ArgumentError("proxy override is not supported when passing an explicit Client"))
            proxy_config = _proxy_config_for_request(req_client, proxy)
            effective_cookiejar = _effective_cookiejar(client, cookiejar)
            incoming_response = _do_incoming!(
                trace,
                req_client,
                parsed.address,
                req,
                parsed.secure,
                parsed.server_name,
                protocol,
                _redirect_policy(req_client, redirect ? redirect_limit : 0, redirect_method, forwardheaders),
                retry_controller,
                proxy_config,
                normalized_cookies,
                effective_cookiejar,
            )
            incoming = incoming_response::_IncomingResponse
            resolved_request = incoming.head.request === nothing ? req : incoming.head.request::Request
            if sse_callback !== nothing
                sse_response = _finalize_request_response(incoming, nobody, Int64(0), resolved_request, parsed.url)
                if !_status_throws(sse_response)
                    _consume_incoming_sse!(incoming, sse_response, sse_callback::Function, decompress)
                    final_response = sse_response
                    return sse_response
                end
            end
            final_body, final_length = _consume_incoming_response!(incoming, sink, decompress, Int(max_decompressed_size))
            response = _finalize_request_response(incoming, final_body, final_length, resolved_request, parsed.url)
            final_response = response
            status_exception && _status_throws(response) && throw(StatusError(response))
            return response
        finally
            owns_client && close(req_client)
        end
    catch err
        if !(err isa CanceledError) && canceled(req_context)
            msg = req_context.cancel_message === nothing ? "request canceled" : req_context.cancel_message::String
            wrapped = CanceledError(msg)
            final_error = wrapped::Exception
            throw(wrapped)
        end
        elapsed_ns = Int64(time_ns()) - request_start_ns
        wrapped = _wrap_client_transport_error(err, "request", request_timeout_ns, elapsed_ns)
        final_error = wrapped::Exception
        wrapped === err ? rethrow() : throw(wrapped)
    finally
        _emit_trace(trace, DoneEvent(final_response, final_error, request_url === nothing ? String(url) : request_url::String))
    end
end

"""
    request(method, url::Union{AbstractString,URI}, headers=Pair{String,String}[], body=nothing; trace=nothing, kwargs...)
    request(trace, method, url::Union{AbstractString,URI}, headers=Pair{String,String}[], body=nothing; kwargs...)

High-level one-shot HTTP request API.

When `trace` is provided, it must be callable on any emitted client event.
Current events are [`RequestEvent`](@ref), [`ResponseHeadEvent`](@ref),
[`RetryEvent`](@ref), [`RedirectEvent`](@ref), and [`DoneEvent`](@ref).

Keyword arguments:
- `basicauth`: optional basic-auth credentials supplied as
  `(username, password)` or `username => password`; explicit
  `Authorization` headers take precedence, and URL `userinfo` is only used as a
  fallback when neither is provided
- `retry`: overall toggle for high-level request retries; lower-level reused-connection transport retries still happen independently
- `retries`: maximum number of retry attempts after the initial request attempt
- `retry_non_idempotent`: allow automatic retries for methods like `POST`/`PATCH`; `PUT` and `DELETE` are already treated as idempotent
- `retry_if`: optional callback `(attempt, err, req, resp) -> Bool | nothing`; request-path failures are passed as `RequestRetryError` so implementations can inspect `err.err`, while response-based retry checks pass `err = nothing` and `resp = response`; `true` forces a retry when the request body is replayable, `false` suppresses retry, and `nothing` defers to built-in retry rules
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
- `cookies`: `true` (default) to use the effective cookie jar, `false` to disable
  cookie send/store for this call, or a dictionary of extra cookie name/value pairs
  to add. When the jar is active, it is merged with any manually-set `Cookie` header,
  de-duplicated by name (jar / `cookies=` entries win); with `false` a manually-set
  `Cookie` header is sent verbatim
- `cookiejar`: optional cookie jar override for this call; explicit clients
  default to `client.cookiejar`, while implicit convenience calls default to the
  shared `HTTP.COOKIEJAR`
- `query`: optional query string or key/value collection appended to the URL
- `response_stream`: optional sink `IO` or byte buffer written with the final response body
- `decompress`: `nothing`/`true` auto-decompress gzip and deflate responses, `false` leaves wire bytes untouched
- `max_decompressed_size`: cap, in bytes, on an auto-decompressed response body; reading past it throws `DecompressionLimitError`, guarding against decompression bombs. `0` (default) disables the limit
- `sse_callback`: callback receiving `(event)` or `(stream, event)` for
  successful SSE responses
- `trace`: optional callback receiving request lifecycle events
- `verbose`: `false` disables built-in logging; `true`/`1` prints high-level
  request lifecycle lines to `stdout`; `2` also prints request and response
  heads. When combined with `trace`, verbose output is emitted before the user
  trace is called.
- `client`: optional explicit `Client`; otherwise a default or ephemeral client
  is created
- `connect_timeout`: connection establishment timeout in seconds, covering DNS,
  TCP connect, HTTP proxy `CONNECT` or SOCKS5 handshakes, TLS handshake, and
  HTTP/2 session setup in the high-level client paths
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

HTTP.jl 2.0 accepts several HTTP.jl 1.x keywords as migration shims:
`readtimeout` maps to `read_idle_timeout`; `pool`, `retry_delays`,
`retry_check`, `sslconfig`, `socket_type_tls`, `copyheaders`,
`canonicalize_headers`, `detect_content_type`, `logerrors`, `logtag`, and
`observelayers` are accepted so older call sites fail less abruptly. Prefer the
2.0 forms listed above for new code: `client` / `transport` for pooling,
`retry_if` / `retry_bucket` for retries, Reseau `Transport` TLS configuration
for TLS/socket behavior, and `verbose` / `trace` for request observation.

The built-in retry policy is intentionally conservative: it retries transient
transport errors plus retryable `408`/`429`/`5xx` responses for replayable
requests, but does not automatically retry request read-timeout/deadline
failures.

Returns a high-level `Response`. When no response body sink is provided,
`response.body` is a fully materialized `Vector{UInt8}`. When `response_stream`
is provided, the final `Response` contains either the filled buffer/view or
`nothing` for `IO` sinks.

# Working with the response body

By default the buffered body is a `Vector{UInt8}`:

```julia
using HTTP

response = HTTP.get("http://example.com")
@assert response.body isa Vector{UInt8}
```

Convert it to a `String` with `String(response.body)`:

```julia
text = String(response.body)
```

!!! warning "`String(response.body)` consumes the bytes"
    `String(::Vector{UInt8})` is the standard Julia conversion and it
    *aliases* the underlying byte buffer rather than copying it. After
    `String(response.body)` runs, `response.body` is left empty (`length == 0`).
    If you want to keep the bytes around, take a copy first
    (`copy(response.body)` or `String(copy(response.body))`), or use the
    `response_stream` keyword to write the body somewhere you own.

# Sending JSON

There is no `json=` keyword. Serialize the payload yourself with the JSON
library of your choice — [JSON.jl](https://github.com/JuliaIO/JSON.jl) is the
recommended option — and set the `Content-Type` header explicitly:

```julia
using HTTP, JSON

payload = Dict("name" => "alice", "age" => 30)
response = HTTP.post(
    "https://api.example.com/users";
    headers = ["Content-Type" => "application/json"],
    body = JSON.json(payload),
)

returned = JSON.parse(String(response.body))
```

Form-encoded payloads (`application/x-www-form-urlencoded`) are auto-derived
from `Dict`/`NamedTuple` bodies, so `HTTP.post(url, [], Dict("a" => "1"))`
sends `a=1` with the matching `Content-Type` header for you.

# Default headers

If the caller does not supply them, HTTP.jl fills in:

- `User-Agent: HTTP.jl/<version>` — override by passing your own `User-Agent`
  header.
- `Accept-Encoding: gzip, deflate` — disable by passing `decompress=false` or
  by setting your own `Accept-Encoding`.

Throws `ArgumentError` for unsupported inputs or invalid sink combinations,
`StatusError` (with `.status` and `.response` fields) when
`status_exception=true` and the response status is considered failing,
`HTTP.TimeoutError` (alias `HTTP.HTTPTimeoutError`) for timeout failures, plus
any lower-level transport or protocol exception raised during the request.
Automatic retries only occur for replayable request bodies.
"""
function request(
    trace,
    method::Union{AbstractString,Symbol},
    url::Union{AbstractString,URI},
    h=Pair{String,String}[],
    b=nothing;
    kwargs...,
)
    return request(method, url, h, b; trace=trace, kwargs...)
end

function _finalize_request_response(
    incoming::_IncomingResponse,
    body,
    body_length::Int64,
    resolved_request::Request,
    request_url::String,
)::Response
    return _response_nocopy_exact(
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

@inline _compose_client_middleware(base, middleware::Tuple{}) = base

function _compose_client_middleware(base, middleware::Tuple)
    return foldr((layer, handler) -> layer(handler), middleware; init=base)
end

@inline function _compose_client_middleware(base, middleware)
    return middleware(base)
end

const _REQUEST_HELPER_DOC = """
    request(method, url, headers=Pair{String,String}[], body=nothing; kwargs...)
    get(url, headers=Pair{String,String}[]; kwargs...)
    head(url, headers=Pair{String,String}[]; kwargs...)
    post(url, [headers], [body]; kwargs...)
    put(url, [headers], [body]; kwargs...)
    patch(url, [headers], [body]; kwargs...)
    delete(url, [headers], [body]; kwargs...)
    options(url, headers=Pair{String,String}[]; kwargs...)

High-level one-shot client request helpers. The verb helpers call
`request(method, ...)` with a fixed HTTP method and accept the same keyword
arguments as `request` — see the [`request`](@ref) docstring for the full
keyword list, the body-encoding rules, and the JSON example.

`response.body` is a `Vector{UInt8}` by default; convert with
`String(response.body)`. Note that the conversion aliases the underlying buffer
and leaves `response.body` empty afterwards — see [`request`](@ref) for the
full warning and the safe-copy idioms.
"""

@doc _REQUEST_HELPER_DOC
function get(url::Union{AbstractString,URI}, headers=Pair{String,String}[]; kwargs...)
    return request("GET", url, headers, nothing; kwargs...)
end

@doc _REQUEST_HELPER_DOC
function head(url::Union{AbstractString,URI}, headers=Pair{String,String}[]; kwargs...)
    return request("HEAD", url, headers, nothing; kwargs...)
end

@doc _REQUEST_HELPER_DOC
function post(url::Union{AbstractString,URI}, args...; kwargs...)
    headers, body = _split_headers_body_args(args)
    return request("POST", url, headers, body; kwargs...)
end

@doc _REQUEST_HELPER_DOC
function put(url::Union{AbstractString,URI}, args...; kwargs...)
    headers, body = _split_headers_body_args(args)
    return request("PUT", url, headers, body; kwargs...)
end

@doc _REQUEST_HELPER_DOC
function patch(url::Union{AbstractString,URI}, args...; kwargs...)
    headers, body = _split_headers_body_args(args)
    return request("PATCH", url, headers, body; kwargs...)
end

@doc _REQUEST_HELPER_DOC
function delete(url::Union{AbstractString,URI}, args...; kwargs...)
    headers, body = _split_headers_body_args(args)
    return request("DELETE", url, headers, body; kwargs...)
end

@doc _REQUEST_HELPER_DOC
function options(url::Union{AbstractString,URI}, headers=Pair{String,String}[]; kwargs...)
    return request("OPTIONS", url, headers, nothing; kwargs...)
end

# Positional `Client` overloads — `HTTP.get(client, url; ...)` is equivalent to
# `HTTP.get(url; client=client, ...)`. These exist so users coming from
# `requests.Session()` / `axios.create()` / `reqwest::Client::builder()` don't
# hit a `MethodError` listing unrelated `Base.get` methods.

request(client::Client, method::Union{AbstractString,Symbol}, url::Union{AbstractString,URI}, args...; kwargs...) =
    request(method, url, args...; client=client, kwargs...)

get(client::Client, url::Union{AbstractString,URI}, headers=Pair{String,String}[]; kwargs...) =
    request("GET", url, headers, nothing; client=client, kwargs...)

head(client::Client, url::Union{AbstractString,URI}, headers=Pair{String,String}[]; kwargs...) =
    request("HEAD", url, headers, nothing; client=client, kwargs...)

function post(client::Client, url::Union{AbstractString,URI}, args...; kwargs...)
    headers, body = _split_headers_body_args(args)
    return request("POST", url, headers, body; client=client, kwargs...)
end

function put(client::Client, url::Union{AbstractString,URI}, args...; kwargs...)
    headers, body = _split_headers_body_args(args)
    return request("PUT", url, headers, body; client=client, kwargs...)
end

function patch(client::Client, url::Union{AbstractString,URI}, args...; kwargs...)
    headers, body = _split_headers_body_args(args)
    return request("PATCH", url, headers, body; client=client, kwargs...)
end

function delete(client::Client, url::Union{AbstractString,URI}, args...; kwargs...)
    headers, body = _split_headers_body_args(args)
    return request("DELETE", url, headers, body; client=client, kwargs...)
end

options(client::Client, url::Union{AbstractString,URI}, headers=Pair{String,String}[]; kwargs...) =
    request("OPTIONS", url, headers, nothing; client=client, kwargs...)

"""
    HTTP.@client request_middleware
    HTTP.@client request_middleware stream_middleware

Define module-local `request`, verb helpers, and `open` methods that wrap the
public HTTP client APIs with custom client-side middleware.

Each middleware must be a callable of the form `mw(next) -> wrapped`, where
`wrapped` matches either:
- `request(method, url, headers, body; kwargs...)` for one-shot requests
- `open(method, url, headers; kwargs...)` for streaming requests

Pass either a single middleware or a tuple of middlewares for each position.
Tuple middlewares are applied from left to right, so `(outer, inner)` runs
`outer(inner(HTTP.request))`.
"""
macro client(request_middleware, stream_middleware=:(()))
    request_handler = gensym(:http_client_request)
    open_handler = gensym(:http_client_open)
    try_ignore = GlobalRef(@__MODULE__, Symbol("@try_ignore"))
    closewrite_ignore = Expr(:macrocall, try_ignore, __source__, quote
        closewrite(stream)
    end)
    expr = quote
        const $request_handler = HTTP._compose_client_middleware(HTTP.request, $request_middleware)
        const $open_handler = HTTP._compose_client_middleware(HTTP.open, $stream_middleware)

        function request(method, url, h=Pair{String,String}[], b=nothing; headers=h, body=b, kwargs...)
            $__source__
            return $request_handler(method, url, headers, body; kwargs...)
        end

        function get(url, headers=Pair{String,String}[]; kwargs...)
            $__source__
            return request("GET", url, headers, nothing; kwargs...)
        end

        function head(url, headers=Pair{String,String}[]; kwargs...)
            $__source__
            return request("HEAD", url, headers, nothing; kwargs...)
        end

        function post(url, args...; kwargs...)
            $__source__
            headers, body = HTTP._split_headers_body_args(args)
            return request("POST", url, headers, body; kwargs...)
        end

        function put(url, args...; kwargs...)
            $__source__
            headers, body = HTTP._split_headers_body_args(args)
            return request("PUT", url, headers, body; kwargs...)
        end

        function patch(url, args...; kwargs...)
            $__source__
            headers, body = HTTP._split_headers_body_args(args)
            return request("PATCH", url, headers, body; kwargs...)
        end

        function delete(url, args...; kwargs...)
            $__source__
            headers, body = HTTP._split_headers_body_args(args)
            return request("DELETE", url, headers, body; kwargs...)
        end

        function options(url, headers=Pair{String,String}[]; kwargs...)
            $__source__
            return request("OPTIONS", url, headers, nothing; kwargs...)
        end

        function open(method::Union{AbstractString,Symbol}, url, headers=Pair{String,String}[]; kwargs...)
            $__source__
            return $open_handler(method, url, headers; kwargs...)
        end

        function open(f::Function, method::Union{AbstractString,Symbol}, url, headers=Pair{String,String}[]; status_exception::Bool=true, kwargs...)
            $__source__
            stream = $open_handler(method, url, headers; kwargs...)
            callback_error = nothing
            try
                f(stream)
            catch err
                callback_error = err
            finally
                $closewrite_ignore
            end
            response = HTTP.closeread(stream)
            if status_exception && HTTP._status_throws(response)
                throw(HTTP.StatusError(response))
            end
            callback_error === nothing || throw(callback_error)
            return response
        end
    end
    return esc(Base.remove_linenums!(expr))
end
