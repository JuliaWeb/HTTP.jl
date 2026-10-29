# High-level HTTP client orchestration, HTTP/2 integration, cookies, response sinks, and convenience APIs.

# Copy-loop buffer for response bodies that are known (or likely) to be large:
# 64 KiB measured faster than 8 KiB and 256 KiB for high-throughput downloads.
# Loops whose payload is typically small — unknown-size accumulation of
# chunked responses and decompression output — keep 8 KiB buffers so a tiny
# response doesn't pay a 64 KiB allocation per request.
const _RESPONSE_COPY_BUFFER_BYTES = 64 * 1024
const _RESPONSE_SMALL_COPY_BUFFER_BYTES = 8 * 1024

"""
    Client(; transport=Transport(proxy=ProxyFromEnvironment()), cookiejar=CookieJar(),
           max_redirects=10, check_redirect=nothing, prefer_http2=true,
           http2_settings=HTTP2Settings(), default_headers=[], default_query=nothing,
           default_basicauth=nothing, connect_timeout=0, request_timeout=0,
           response_header_timeout=0, read_idle_timeout=0, write_idle_timeout=0,
           local_addr=nothing)

An HTTP client: a connection pool plus the settings and cookies that requests
sent through it share. Pass it to `request`, the verb helpers, or `open` as the
first argument or as the `client` keyword. Calls without a client use a shared
default `Client`. `close(client)` closes its connections; using a closed client
throws `ArgumentError`.

- `transport`: the [`Transport`](@ref) that owns the connections. The default
  one takes its proxy from the environment.
- `cookiejar`: the [`CookieJar`](@ref) for this client, or `nothing` for no
  cookies.
- `max_redirects`: the most redirects one request follows.
- `check_redirect`: a function `(response, request, location) -> Bool`; return
  `false` to stop at a redirect and return it.
- `prefer_http2`: try HTTP/2 for `https://` URLs. When an origin turns out to
  speak only HTTP/1.1, the client remembers that until
  [`close_idle_connections!`](@ref). `protocol = :h2` on a call always tries
  HTTP/2.
- `http2_settings`: the [`HTTP2Settings`](@ref) for HTTP/2 connections.
- `default_headers`: headers added to each request that does not set them.
- `default_query`: query parameters added to each URL; the call's `query`
  replaces those with the same key.
- `default_basicauth`: `user => password` used unless the call passes
  `basicauth` or an `Authorization` header.
- `connect_timeout`, `request_timeout`, `response_header_timeout`,
  `read_idle_timeout`, `write_idle_timeout`: timeouts in seconds, used when the
  call passes no value or `0`. `0` here means no default.
- `local_addr`: the source IP address for connections, as a string or a
  `Reseau.TCP.SocketAddrV4`/`SocketAddrV6`. With your own `transport`, set it on
  the `Transport` instead.
"""
mutable struct Client{CR}
    transport::Transport
    check_redirect::CR
    cookiejar::Union{Nothing,CookieJar}
    max_redirects::Int
    prefer_http2::Bool
    http2_settings::HTTP2Settings
    h2_lock::ReentrantLock
    h2_conns::Dict{String,Vector{H2Connection}}
    # Origins that negotiated HTTP/1.1 during `protocol = :auto`. Guarded by
    # its own lock (never `h2_lock`): `h2_lock` is held across full TCP+TLS
    # dials in `_acquire_h2_conn!`, and the hot-path membership check in
    # `_use_h2` must not serialize behind those dials.
    h1_origins_lock::ReentrantLock
    h1_origins::Set{String}
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
    RetrySkippedEvent

Trace event emitted when the retry policy wanted to retry an attempt but the
retry was not armed, so the attempt's failure becomes the request's outcome.
Without this event a denied retry is indistinguishable from a non-retryable
failure.

Fields:
- `request`: request metadata for the attempt that will not be retried
- `url`: absolute request URL for the attempt
- `attempt`: current 1-based attempt number
- `redirect_count`: redirects already followed when the retry decision was made
- `reason`: `:retry_bucket` when the transport's [`RetryBucket`](@ref) denied
  retry capacity; `:deadline` when the request deadline preempted the retry
  backoff
- `response`: retry-triggering response, or `nothing` for request-path failures
- `err`: retry-triggering exception, or `nothing` for response-based retries
"""
struct RetrySkippedEvent <: ClientEvent
    request::Request
    url::String
    attempt::Int
    redirect_count::Int
    reason::Symbol
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

# `maxlog` counts per `_id`, so each keyword name gets its own id and warns once.
@inline function _warn_ignored_client_compat_kw(name::AbstractString)::Nothing
    @warn "`$name` is accepted for compatibility but is no longer supported in the HTTP 2.0 client and has no effect" maxlog=1 _id=Symbol("HTTP_compat_kw_", name)
    return nothing
end

@inline function _warn_unimplemented_client_compat_kw(name::AbstractString)::Nothing
    @warn "`$name` is accepted for compatibility but is not implemented yet in the HTTP 2.0 client" maxlog=1 _id=Symbol("HTTP_compat_kw_", name)
    return nothing
end

function _handle_client_compat_kwargs(;
    copyheaders=nothing,
    pool=nothing,
    detect_content_type=nothing,
    observelayers=nothing,
    retry_delays=nothing,
    retry_check=nothing,
    sslconfig=nothing,
    socket_type_tls=nothing,
    logerrors=nothing,
    logtag=nothing,
)::Nothing
    pool === nothing || _warn_ignored_client_compat_kw("pool")
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

function (trace::_VerboseTrace)(event::RetrySkippedEvent)::Nothing
    detail = if event.err !== nothing
        sprint(showerror, event.err::Exception)
    elseif event.response !== nothing
        string("status ", (event.response::Response).status)
    else
        "failure"
    end
    _verbose_line!(string("retry of attempt ", event.attempt, " skipped (", event.reason, ") after ", detail))
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
    transport::Union{Nothing,Transport}=nothing,
    check_redirect=nothing,
    cookiejar::Union{Nothing,CookieJar}=CookieJar(),
    max_redirects::Integer=10,
    prefer_http2::Bool=true,
    http2_settings::HTTP2Settings=HTTP2Settings(),
    default_headers=Pair{String,String}[],
    default_query=nothing,
    default_basicauth=nothing,
    connect_timeout::Real=0,
    request_timeout::Real=0,
    response_header_timeout::Real=0,
    read_idle_timeout::Real=0,
    write_idle_timeout::Real=0,
    local_addr=nothing,
)
    max_redirects >= 0 || throw(ArgumentError("max_redirects must be >= 0"))
    # `local_addr` is a convenience that binds outbound connections to a source
    # IP/interface (Go's net.Dialer.LocalAddr model). It belongs to the
    # transport's connection pool, so it folds into the default transport; if the
    # caller supplies their own transport, they must set it there instead.
    if transport === nothing
        transport = Transport(proxy=ProxyFromEnvironment(), local_addr=local_addr)
    elseif local_addr !== nothing
        throw(ArgumentError("local_addr cannot be combined with an explicit `transport`; pass local_addr to Transport(...) instead"))
    end
    return Client{typeof(check_redirect)}(
        transport,
        check_redirect,
        cookiejar,
        Int(max_redirects),
        prefer_http2,
        http2_settings,
        ReentrantLock(),
        Dict{String,Vector{H2Connection}}(),
        ReentrantLock(),
        Set{String}(),
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

# A summary without the default credentials, query values, or cookies.
function Base.show(io::IO, client::Client)
    print(io, "HTTP.Client(", isopen(client) ? "open" : "closed",
        ", max_redirects=", client.max_redirects,
        ", prefer_http2=", client.prefer_http2,
        ", cookiejar=", client.cookiejar === nothing ? "nothing" : "CookieJar",
        ", default_headers=", length(client.default_headers),
        ", default_query=", client.default_query === nothing ? 0 : length(client.default_query::Vector{Pair{String,String}}),
        ", default_basicauth=", client.default_basicauth === nothing ? "nothing" : "set",
        ", transport=")
    show(io, client.transport)
    print(io, ")")
    return nothing
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
    server_name::Union{Nothing,String}=nothing;
    allow_h1_alpn::Bool=false,
    auto_protocol::Bool=false,
)::Tuple{H2Connection,Bool}
    key = _h2_key(plan)
    # Fail fast (and without touching `h2_lock`) when another task cached this
    # origin as HTTP/1.1 after our caller's `_use_h2` check.
    if auto_protocol && _h1_origin_cached(client, key)
        throw(H2NegotiationError("http2: origin previously negotiated HTTP/1.1"))
    end
    base_host_resolver = client.transport.host_resolver
    connect_host_resolver = request === nothing ? base_host_resolver : _request_connect_host_resolver(base_host_resolver, request::Request)
    connect_deadline_ns = request === nothing ? _phase_deadline_ns(base_host_resolver.timeout_ns, base_host_resolver.deadline_ns) : _request_connect_phase_deadline_ns(base_host_resolver, request::Request)
    tls_handshake_timeout_ns = request === nothing ? Int64(0) : _request_connect_phase_timeout_ns(base_host_resolver, request::Request)
    # Connections culled from the pool are closed after `h2_lock` is released:
    # closing an H2Connection waits for its read loop to exit, and that must
    # not happen while holding the pool lock.
    to_close = H2Connection[]
    waited_for_h2_lock = !trylock(client.h2_lock)
    waited_for_h2_lock && lock(client.h2_lock)
    try
        # The origin can be cached while this task waits for `h2_lock`. Only
        # contended acquisitions need this second check, so the uncontended h2
        # fast path does not pay for another cache lookup.
        if waited_for_h2_lock && auto_protocol && _h1_origin_cached(client, key)
            throw(H2NegotiationError("http2: origin previously negotiated HTTP/1.1"))
        end
        conns = get(() -> H2Connection[], client.h2_conns, key)
        idle_timeout_ns = client.transport.idle_timeout_ns
        now_ns = Int64(time_ns())
        i = 1
        while i <= length(conns)
            existing = conns[i]
            # Evict connections idle past the pool's idle timeout before
            # considering them for reuse: a NAT or load balancer may have
            # silently dropped the flow, and the first read on such a
            # connection stalls until the kernel retransmission limit (#1331).
            if _h2_conn_idle_expired(existing::H2Connection, idle_timeout_ns, now_ns)
                deleteat!(conns, i)
                push!(to_close, existing::H2Connection)
                continue
            end
            if !_h2_conn_available(existing::H2Connection)
                # A failed connection is already closed. One that takes no new
                # streams stays until its last stream ends and it closes itself.
                if @atomic :acquire (existing::H2Connection).closed
                    deleteat!(conns, i)
                    continue
                end
            else
                # Atomically claim a pending slot so a concurrent acquirer
                # entering this loop doesn't see the same `existing` as
                # available before our caller calls `_register_stream!`.
                if _try_claim_h2_pending_slot!(existing::H2Connection)
                    return existing::H2Connection, true
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
        conn = try
            if plan.mode == _ProxyPlanMode.DIRECT
                connect_h2!(
                    address;
                    secure=secure,
                    host_resolver=connect_host_resolver,
                    tls_config=tls_cfg,
                    connect_deadline_ns=connect_deadline_ns,
                    http2_settings=client.http2_settings,
                )
            elseif plan.mode == _ProxyPlanMode.HTTP_TUNNEL || _proxy_plan_is_socks(plan)
                proxy = plan.proxy
                proxy === nothing && throw(ProtocolError("proxy connection is missing proxy config"))
                tcp = _new_tcp_conn!(plan, address, connect_host_resolver, connect_deadline_ns)
                try
                    _connect_h2_from_tcp!(
                        tcp,
                        address,
                        secure,
                        tls_cfg,
                        connect_deadline_ns,
                        client.http2_settings,
                        connect_host_resolver.deadline_ns,
                    )
                catch
                    @try_ignore begin
                        TCP.close(tcp)
                    end
                    rethrow()
                end
            else
                throw(ArgumentError("HTTP/2 is not supported for proxy plan mode $(plan.mode)"))
            end
        catch err
            if auto_protocol && _should_fallback_h2_to_h1(err)
                _cache_h1_origin!(client, key)
            end
            rethrow()
        end
        # Claim a slot on the freshly opened connection up front so subsequent
        # acquirers that race in see this caller's pending request. The claim
        # fails when the peer allows no streams yet; the request then waits
        # for a slot without holding one.
        claimed = _try_claim_h2_pending_slot!(conn::H2Connection)
        push!(conns, conn)
        client.h2_conns[key] = conns
        return conn::H2Connection, claimed
    finally
        unlock(client.h2_lock)
        for culled in to_close
            @try_ignore begin
                close(culled)
            end
        end
    end
end

@inline function _should_fallback_h2_to_h1(err)::Bool
    return err isa H2NegotiationError
end

function _use_h2(client::Client, plan::_ProxyPlan, secure::Bool, protocol::Symbol)::Bool
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
    return !_h1_origin_cached(client, _h2_key(plan))
end

@inline function _h1_origin_cached(client::Client, key::String)::Bool
    lock(client.h1_origins_lock)
    try
        return key in client.h1_origins
    finally
        unlock(client.h1_origins_lock)
    end
end

function _cache_h1_origin!(client::Client, key::String)::Nothing
    lock(client.h1_origins_lock)
    try
        push!(client.h1_origins, key)
    finally
        unlock(client.h1_origins_lock)
    end
    return nothing
end

# Cookies match against the request path without its query (RFC 6265 §5.1.4).
function _host_path_from_request(address::String, request::Request)::Tuple{String,String}
    host, _ = HostResolvers.split_host_port(address)
    path, _ = _split_request_target(request.target)
    if isempty(path)
        return host, "/"
    end
    startswith(path, "/") && return host, path
    return host, "/$path"
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
    # Merge a caller-set `Cookie` header with the managed cookies (the jar plus
    # `cookies=`). Managed cookies win: the manual header only adds names they
    # do not already have, so a stale manual value never shadows a rotated jar
    # cookie. `cookies=false` sends a manual `Cookie` header verbatim.
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
    # BytesBody retains its backing bytes by contract. A replay only needs an
    # independent cursor and closed flag; copying the payload makes every
    # buffered upload allocate and copy the complete request body again.
    return BytesBody(body.data, body.next_index, false)
end

function _clone_body(body::AbstractBody)::AbstractBody
    body isa EmptyBody && return EmptyBody()
    body isa BytesBody && return _clone_bytes_body(body::BytesBody)
    throw(ProtocolError("request body is not replayable"))
end

function _copy_request(request::Request)
    # A declared empty payload needs no producer when it is replayed.
    body = request.content_length == 0 && !_body_replayable(request.body) ?
        EmptyBody() : _clone_body(request.body)
    return _request_nocopy(
        request.method,
        request.target,
        copy(request.headers),
        copy(request.trailers),
        body,
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

function _copy_request_for_send(request::Request, allow_nonreplayable::Bool=false)::Request
    if allow_nonreplayable && !_body_replayable(request.body)
        # The first send retains the producer so the transport closes it.
        return _copy_request_shallow_body(request)
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
    cookiejar::Union{Nothing,CookieJar}=client.cookiejar;
    copyrequest::Bool=true,
)
    current_address = String(address)
    initial_address = current_address
    current_secure = secure
    # Remember the original request scheme so the sensitive-header same-origin
    # check below can detect an https->http downgrade across the redirect chain.
    initial_secure = secure
    # A `server_name` equal to the host in `address` is not treated as pinned,
    # so SNI and certificate checks follow redirects to other hosts. Only a
    # different, explicit `server_name` is kept on every hop.
    auto_server_name = _host_for_sni(current_address)
    user_pinned_server_name = server_name !== nothing && String(server_name::AbstractString) != auto_server_name
    current_server_name = user_pinned_server_name ? String(server_name::AbstractString) : auto_server_name
    current_request = copyrequest ? _copy_request_shallow_body(request) : request
    previous_response = nothing
    retry_attempt = 1
    retry_token = nothing
    retry_custom_wanted = false
    for redirect_count in 0:redirect_policy.max_redirects
        while true
            send_request, request_url, proxy_plan, use_h2, host, path = try
                # A request line that cannot be sent fails here, before a
                # connection is made, and is not retried.
                _validate_request_start_line!(current_request.method, current_request.target)
                next_request = _copy_request_for_send(current_request, retry_attempt == 1)
                next_url = _request_url(current_secure, current_address, current_request.target)
                next_proxy_plan = _proxy_plan(proxy_config, current_secure, current_address)
                next_use_h2 = next_proxy_plan.mode != _ProxyPlanMode.HTTP_FORWARD &&
                    _use_h2(client, next_proxy_plan, current_secure, protocol)
                _emit_trace(trace, RequestEvent(next_request, next_url, retry_attempt, redirect_count, next_use_h2 ? :h2 : :h1))
                next_host, next_path = _host_path_from_request(current_address, current_request)
                manual_cookies = cookies === false ? Cookie[] : Cookies.readcookies(next_request.headers, "")
                cookie_value = _cookie_header(cookiejar, cookies, current_secure, next_host, next_path, manual_cookies)
                cookie_value === nothing || setheader(next_request.headers, "Cookie", cookie_value)
                (next_request, next_url, next_proxy_plan, next_use_h2, next_host, next_path)
            catch
                if retry_token !== nothing
                    @try_ignore _settle_request_retry_token!(retry_token::RetryToken, 0)
                    retry_token = nothing
                    retry_custom_wanted = false
                end
                rethrow()
            end
            response = try
                if use_h2
                    # A failed request leaves its pooled connection to the other
                    # requests on it; a failed connection is already closed and
                    # leaves the pool on the next acquire.
                    try
                        conn, claimed = _acquire_h2_conn!(
                            client,
                            proxy_plan,
                            current_address,
                            current_secure,
                            send_request,
                            current_server_name;
                            allow_h1_alpn=(protocol == :auto),
                            auto_protocol=(protocol == :auto),
                        )
                        _h2_roundtrip_incoming!(conn, send_request; pending_slot_claimed=claimed, pooled=true)
                    catch err
                        if protocol == :auto && _should_fallback_h2_to_h1(err)
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
                if retry_token !== nothing
                    _settle_request_retry_token!(retry_token::RetryToken, _RETRY_BUCKET_ACQUIRE_COST)
                end
                retry_token = nothing
                retry_custom_wanted = false
                if retry_controller !== nothing
                    can_retry = retry_controller.enabled && retry_controller.remaining > 0
                    retry_wanted, custom_wanted = can_retry ?
                        _retry_policy_decision(retry_controller, retry_attempt, current_request, RequestRetryError(err::Exception), nothing) :
                        (false, false)
                    if retry_wanted
                        scheduled, next_token, delay_ns, skip_reason = _arm_request_retry!(retry_controller, current_address, current_request, retry_attempt, nothing)
                        if scheduled
                            try
                                _emit_trace(trace, RetryEvent(current_request, request_url, retry_attempt, retry_attempt + 1, redirect_count, delay_ns, nothing, err::Exception))
                                get_request_context(current_request)[:retryattempt] = retry_attempt
                            catch
                                next_token === nothing || @try_ignore _settle_request_retry_token!(next_token::RetryToken, 0)
                                rethrow()
                            end
                            retry_attempt += 1
                            retry_token = next_token
                            retry_custom_wanted = custom_wanted
                            continue
                        end
                        skip_reason === nothing || _emit_trace(trace, RetrySkippedEvent(current_request, request_url, retry_attempt, redirect_count, skip_reason::Symbol, nothing, err::Exception))
                    end
                end
                rethrow(err)
            end
            response = try
                response = _annotate_incoming_response(
                    response,
                    request_url,
                    previous_response,
                    redirect_count,
                )
                _store_set_cookies!(cookiejar, cookies, current_secure, host, path, response.head.headers)
                status_response = _retry_policy_response(response, current_request)
                _emit_trace(trace, ResponseHeadEvent(status_response, request_url, retry_attempt, redirect_count))

                can_retry = retry_controller !== nothing && retry_controller.enabled && retry_controller.remaining > 0
                retry_wanted, custom_wanted = can_retry ?
                    _retry_policy_decision(retry_controller, retry_attempt, current_request, nothing, status_response) :
                    (false, false)
                if retry_controller !== nothing && retry_controller.bucket !== nothing
                    response_bucket = retry_controller.bucket::RetryBucket
                    if retry_token !== nothing
                        terminal_builtin_failure = !can_retry &&
                            _retry_builtin_wants_retry(retry_controller, current_request, nothing, status_response)
                        terminal_custom_failure = !can_retry && retry_custom_wanted &&
                            !_successful_response_status(status_response.status)
                        failure_cost = _retry_bucket_response_cost(
                            retry_wanted || terminal_builtin_failure || terminal_custom_failure,
                        )
                        _settle_request_retry_token!(retry_token::RetryToken, failure_cost)
                    elseif !retry_wanted && _successful_response_status(status_response.status)
                        # Healthy non-retried traffic slowly restores retry
                        # capacity consumed by an earlier failure burst.
                        _retry_bucket_replenish!(response_bucket, _retry_partition_for_address(current_address))
                    end
                end
                retry_token = nothing
                retry_custom_wanted = false

                if retry_wanted
                    scheduled, next_token, delay_ns, skip_reason = _arm_request_retry!(retry_controller, current_address, current_request, retry_attempt, status_response)
                    if scheduled
                        try
                            _emit_trace(trace, RetryEvent(current_request, request_url, retry_attempt, retry_attempt + 1, redirect_count, delay_ns, status_response, nothing))
                            get_request_context(current_request)[:retryattempt] = retry_attempt
                        catch
                            next_token === nothing || @try_ignore _settle_request_retry_token!(next_token::RetryToken, 0)
                            rethrow()
                        end
                        retry_attempt += 1
                        retry_token = next_token
                        retry_custom_wanted = custom_wanted
                        @try_ignore begin
                            body_close!(response.rawbody)
                        end
                        continue
                    end
                    skip_reason === nothing || _emit_trace(trace, RetrySkippedEvent(current_request, request_url, retry_attempt, redirect_count, skip_reason::Symbol, status_response, nothing))
                end

                response
            catch
                if retry_token !== nothing
                    # A response arrived, but a trace or policy callback failed
                    # before the custom decision could settle the reservation.
                    fallback_cost = _retry_bucket_failure_cost(response.head.status)
                    if retry_custom_wanted && !_successful_response_status(response.head.status)
                        fallback_cost = max(fallback_cost, _RETRY_BUCKET_RETRYABLE_RESPONSE_COST)
                    end
                    @try_ignore _settle_request_retry_token!(retry_token::RetryToken, fallback_cost)
                    retry_token = nothing
                    retry_custom_wanted = false
                end
                @try_ignore body_close!(response.rawbody)
                rethrow()
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
            next_address, next_secure, next_target, next_host_header = _resolve_redirect_target(current_address, current_secure, location, current_request.target, current_request.host)
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
            # Recompute the TLS verification host (SNI) from the redirect target
            # unless the caller genuinely pinned a server_name. Otherwise TLS
            # would verify the peer certificate against the original host while
            # the TCP connection is dialed to the redirect target.
            if !user_pinned_server_name
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
            # Compare the FULL origin (scheme + host + port) of the current hop
            # against the original request origin. On any cross-origin hop, strip
            # credential headers AND stop re-applying per-call explicit cookies,
            # which are otherwise re-attached by `_cookie_header` on every hop
            # even after the Cookie header was stripped here, leaking them to the
            # redirect target.
            if !_should_copy_sensitive_headers_on_redirect(initial_address, current_address, initial_secure, current_secure)
                _strip_sensitive_redirect_headers!(current_request.headers)
                # Drop caller-supplied (`cookies=`) cookies once we leave the
                # original origin so they are not re-merged into the Cookie
                # header on subsequent hops. Jar-derived cookies remain
                # host-scoped via `getcookies!`, so disabling only the explicit
                # vector is sufficient; `false` keeps the jar active.
                if cookies isa Vector{Cookie}
                    cookies = Cookie[]
                end
            end
            current_request.host = next_host_header
            break
        end
    end
    throw(ProtocolError("unexpected redirect loop termination"))
end

"""
    do!(client, address, request; secure=false, server_name=nothing, protocol=:auto,
        redirect_limit=nothing, redirect_method=nothing, forwardheaders=true,
        cookies=true, cookiejar=nothing, context=nothing) -> Response

Send a prepared `request` to `address` (`"host:port"`) through `client`,
following redirects and using cookies like [`request`](@ref), but without
retries or status errors. `secure = true` connects with TLS.

The response body is a stream: read it with [`body_read!`](@ref) and close it
with [`body_close!`](@ref).
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
            # An HTTP/2 response whose stream already ended when its head was
            # read (204, HEAD, an empty body) has an `EmptyBody`.
            return _streaming_response(incoming::Union{_IncomingResponse{H2Body},_IncomingResponse{EmptyBody}})
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
            return _streaming_response(incoming::Union{_IncomingResponse{H1Body},_IncomingResponse{H2Body},_IncomingResponse{EmptyBody}})
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
        wrapped = err isa Exception ? _wrap_client_transport_error(err::Exception, "request", timeout_ns, elapsed_ns) : err
        wrapped === err ? rethrow() : throw(wrapped)
    end
end

import Base: get, get!

"""
    get!(client, address, target; secure=false, protocol=:auto, kwargs...) -> Response

Send a `GET` request for `target` to `address` with [`do!`](@ref).
"""
function get!(client::Client, address::AbstractString, target::AbstractString; secure::Bool=false, protocol::Symbol=:auto, kwargs...)
    request = Request("GET", target; host=String(address), body=EmptyBody(), content_length=0)
    return do!(client, address, request; secure=secure, protocol=protocol, kwargs...)
end

"""
    StatusError

Raised by `request` and the verb helpers for a response with status 300 or
above that is not a redirect, unless `status_exception = false`.

Fields:

- `status::Int16`: the response status.
- `response::Response`: the response, including its body.
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
    retry_attempts(request) -> Int
    retry_attempts(response) -> Int

Return how many times the client retried the request, `0` when the first
attempt was the only one. The count is also stored as
`request.context[:retryattempt]`.
"""
retry_attempts(request::Request)::Int = Int(get(get_request_context(request), :retryattempt, 0))

function retry_attempts(response::Response)::Int
    request = response.request
    return request === nothing ? 0 : retry_attempts(request::Request)
end

"""
    TooManyRedirectsError

Raised when a request reaches its redirect limit and gets another redirect.
`limit` is the limit and `response` is the last redirect response.
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

function close_idle_connections!(client::Client)
    close_idle_connections!(client.transport)
    # Drop cached HTTP/1.1 negotiation results so long-lived clients re-probe
    # origins that may have enabled HTTP/2 since they were first contacted.
    lock(client.h1_origins_lock)
    try
        empty!(client.h1_origins)
    finally
        unlock(client.h1_origins_lock)
    end
    # Also close pooled HTTP/2 connections with no in-flight streams — these
    # live on the Client (not the Transport pool) and are equally subject to
    # silent idle drops by NATs/load balancers (#1331). Connections carrying
    # active streams or pending reservations are left untouched. Closing
    # happens after `h2_lock` is released (close waits for the read loop).
    to_close = H2Connection[]
    lock(client.h2_lock)
    try
        for key in collect(keys(client.h2_conns))
            conns = client.h2_conns[key]
            kept = H2Connection[]
            for conn in conns
                if _h2_conn_fully_idle(conn)
                    push!(to_close, conn)
                else
                    push!(kept, conn)
                end
            end
            if isempty(kept)
                pop!(client.h2_conns, key, nothing)
            else
                client.h2_conns[key] = kept
            end
        end
    finally
        unlock(client.h2_lock)
    end
    for conn in to_close
        @try_ignore begin
            close(conn)
        end
    end
    return nothing
end

function close_idle_connections!()
    lock(_DEFAULT_CLIENT_LOCK)
    client = try
        _DEFAULT_CLIENT[]
    finally
        unlock(_DEFAULT_CLIENT_LOCK)
    end
    client === nothing && return nothing
    return close_idle_connections!(client)
end

function _status_throws(status::Int)::Bool
    return status >= 300 && !_is_redirect_status(status)
end

_status_throws(resp::Response)::Bool = _status_throws(resp.status)

function _read_all_response_bytes(io::IO, limit::Int=0)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, _RESPONSE_SMALL_COPY_BUFFER_BYTES)
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

function _grow_response_bytes(out::Vector{UInt8}, filled::Int, len::Int)::Vector{UInt8}
    grown = Vector{UInt8}(undef, len)
    copyto!(grown, 1, out, 1, filled)
    return grown
end

# Reads a body declared larger than `_MAX_EAGER_RESPONSE_PREALLOC` into a vector
# that grows toward the declared length only as bytes arrive. A false length
# cannot make it allocate more than about twice what was received, and a true
# one leaves an exact-size vector.
function _read_response_bytes_toward_hint(body::Union{EmptyBody,BytesBody,H1Body,H2Body}, hint::Int64)::Vector{UInt8}
    out = Vector{UInt8}(undef, Int(_MAX_EAGER_RESPONSE_PREALLOC))
    total = 0
    while true
        if total == length(out)
            if total >= hint
                # The declared length arrived; grow past it only for more bytes.
                byte = Vector{UInt8}(undef, 1)
                body_read!(body, byte) == 0 && return out
                out = _grow_response_bytes(out, total, 2 * total)
                total += 1
                out[total] = byte[1]
                continue
            end
            out = _grow_response_bytes(out, total, Int(min(2 * Int64(total), hint)))
        end
        # Bounded reads, as in `_copy_response_bytes!`: each read restarts the
        # read idle timeout.
        stop = min(length(out), total + _RESPONSE_COPY_BUFFER_BYTES)
        n = body_read!(body, @view(out[(total + 1):stop]))
        n == 0 && return resize!(out, total)
        total += n
    end
end

function _read_all_response_bytes(body::AbstractBody, content_length_hint::Int64=Int64(-1))::Vector{UInt8}
    if 0 <= content_length_hint <= _MAX_EAGER_RESPONSE_PREALLOC
        out = Vector{UInt8}(undef, Int(content_length_hint))
        n = _copy_response_bytes!(out, body)
        n == content_length_hint || resize!(out, Int(n))
        return out
    end
    if content_length_hint > _MAX_EAGER_RESPONSE_PREALLOC && body isa Union{EmptyBody,BytesBody,H1Body,H2Body}
        return _read_response_bytes_toward_hint(body, content_length_hint)
    end
    out = UInt8[]
    content_length_hint > 0 && sizehint!(out, Int(min(content_length_hint, _MAX_EAGER_RESPONSE_PREALLOC)))
    # A hint above the prealloc cap means a known-large download; without a
    # hint (chunked/EOF-framed) the body is usually small, so stay at 8 KiB.
    buf_bytes = content_length_hint > _MAX_EAGER_RESPONSE_PREALLOC ? _RESPONSE_COPY_BUFFER_BYTES : _RESPONSE_SMALL_COPY_BUFFER_BYTES
    buf = Vector{UInt8}(undef, buf_bytes)
    while true
        n = body_read!(body, buf)
        n == 0 && return out
        append!(out, @view(buf[1:n]))
    end
end

function _copy_response_bytes!(dest::IO, io::IO, limit::Int=0)::Int64
    buf = Vector{UInt8}(undef, _RESPONSE_SMALL_COPY_BUFFER_BYTES)
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
    capacity = length(dest)
    # `dest` is preallocated to the expected size; a small response should not
    # pay a 64 KiB scratch allocation. The 1-byte floor keeps the capacity
    # overflow check below reachable when `dest` is empty.
    buf = Vector{UInt8}(undef, min(max(capacity, 1), _RESPONSE_COPY_BUFFER_BYTES))
    total = 0
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
    buf = Vector{UInt8}(undef, _RESPONSE_COPY_BUFFER_BYTES)
    total = Int64(0)
    while true
        n = body_read!(body, buf)
        n == 0 && return total
        total += n
        write(dest, view(buf, 1:n))
    end
end

function _copy_response_bytes!(dest::AbstractVector{UInt8}, body::AbstractBody)::Int64
    capacity = length(dest)
    # See the sizing rationale on the `io::IO` method above.
    buf = Vector{UInt8}(undef, min(max(capacity, 1), _RESPONSE_COPY_BUFFER_BYTES))
    total = 0
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

# Built-in buffered and network bodies accept destination views. Custom bodies
# retain the Vector-based scratch fallback above, including callback bodies.
function _copy_response_bytes!(dest::AbstractVector{UInt8}, body::Union{EmptyBody,BytesBody,H1Body,H2Body})::Int64
    capacity = length(dest)
    total = 0
    while total < capacity
        stop = min(capacity, total + _RESPONSE_COPY_BUFFER_BYTES)
        n = body_read!(body, @view dest[(total + 1):stop])
        n == 0 && break
        total += n
    end
    if total == capacity
        # Read through EOF/trailers and detect overflow without writing outside
        # the caller's storage. An empty destination still checks for data.
        n = body_read!(body, Vector{UInt8}(undef, 1))
        n == 0 || throw(ArgumentError("Unable to grow response stream IOBuffer $(capacity) large enough for response body size: $(total + n)"))
    end
    dest isa Vector{UInt8} && resize!(dest, total)
    return Int64(total)
end

function _response_content_encoding(headers::Headers, decompress::Union{Nothing,Bool})::Union{Nothing,Symbol}
    decompress === false && return nothing
    encoding = header(headers, "Content-Encoding", nothing)
    encoding === nothing && return nothing
    normalized = _ascii_lowercase_string(strip(encoding))
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
    buf = Vector{UInt8}(undef, _RESPONSE_COPY_BUFFER_BYTES)
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
    buf = Vector{UInt8}(undef, _RESPONSE_SMALL_COPY_BUFFER_BYTES)
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

const _DEFAULT_MAX_DECOMPRESSED_SIZE = Int(64 * 1024 * 1024)

function Base.showerror(io::IO, err::DecompressionLimitError)
    print(io, "DecompressionLimitError: decompressed response body exceeded max_decompressed_size = ", err.limit, " bytes")
    return nothing
end

# Decodes `Content-Encoding: deflate`. RFC 9110 defines it as a zlib stream
# (RFC 1950), but some servers, such as ones using .NET's `DeflateStream`, send
# raw DEFLATE data (RFC 1951). Like browsers and curl, accept both. The first
# byte of a zlib stream always has 8 in its low nibble; a raw stream would need
# nonzero padding bits in its first block header to match, which encoders never
# write. The decoder is picked on the first input, so nothing is read early.
mutable struct _DeflateDecompressor <: TranscodingStreams.Codec
    codec::Union{Nothing,CodecZlib.ZlibDecompressor,CodecZlib.DeflateDecompressor}
end

function TranscodingStreams.startproc(codec::_DeflateDecompressor, mode::Symbol, error::TranscodingStreams.Error)::Symbol
    inner = codec.codec
    return inner === nothing ? :ok : TranscodingStreams.startproc(inner, mode, error)
end

function TranscodingStreams.process(
    codec::_DeflateDecompressor,
    input::TranscodingStreams.Memory,
    output::TranscodingStreams.Memory,
    error::TranscodingStreams.Error,
)
    inner = codec.codec
    if inner === nothing
        # An empty body has no first byte; it keeps the zlib decoder's handling.
        raw = input.size > 0 && (unsafe_load(input.ptr) & 0x0f) != 0x08
        inner = raw ? CodecZlib.DeflateDecompressor() : CodecZlib.ZlibDecompressor()
        codec.codec = inner
        code = TranscodingStreams.startproc(inner, :read, error)
        code === :ok || return 0, 0, code
    end
    return TranscodingStreams.process(inner, input, output, error)
end

function TranscodingStreams.finalize(codec::_DeflateDecompressor)::Nothing
    inner = codec.codec
    inner === nothing || TranscodingStreams.finalize(inner)
    return nothing
end

function _decompressor_stream(io::IO, encoding::Symbol)
    encoding === :gzip && return CodecZlib.GzipDecompressorStream(io)
    return TranscodingStreams.TranscodingStream(_DeflateDecompressor(nothing), io)
end

function _response_body_reader(incoming::_IncomingResponse, decompress::Union{Nothing,Bool})::Tuple{IO,Union{Nothing,Task}}
    raw_stream = _BodyIO(incoming.rawbody)
    encoding = _response_content_encoding(incoming.head.headers, decompress)
    encoding === nothing && return raw_stream, nothing
    return _decompressor_stream(raw_stream, encoding), nothing
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

# Bounds the body kept for a response whose byte-buffer sink is left untouched.
const _MAX_NON_2XX_BODY_BYTES = 1 << 20

# Reads at most `limit` body bytes; closing the reader discards the rest.
function _read_response_prefix(incoming::_IncomingResponse, decompress::Union{Nothing,Bool}, limit::Int)::Vector{UInt8}
    return _with_response_reader(incoming, decompress) do reader
        out = UInt8[]
        buf = Vector{UInt8}(undef, _RESPONSE_SMALL_COPY_BUFFER_BYTES)
        while length(out) < limit
            n = readbytes!(reader, buf, min(length(buf), limit - length(out)))
            n == 0 && break
            append!(out, @view(buf[1:n]))
        end
        return out
    end
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

function _normalize_headers_input(headers_input, copyheaders::Bool=true)::Headers
    headers_input === nothing && return Headers()
    headers_input isa Headers && return copyheaders ? copy(headers_input) : headers_input
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

# `canonicalize_headers=true`: rewrite caller-spelled names in place, e.g.
# `x-request-id` becomes `X-Request-Id`.
function _canonicalize_header_names!(headers::Headers)::Nothing
    entries = headers.entries
    @inbounds for i in eachindex(entries)
        key, value = entries[i]
        entries[i] = canonical_header_key(key) => value
    end
    return nothing
end

function _apply_default_accept_encoding!(headers::Headers, decompress::Union{Nothing,Bool})::Nothing
    decompress === false && return nothing
    haskey(headers, "Accept-Encoding") && return nothing
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
    return _fast_uppercase(String(method))
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

const _DEFAULT_CONNECT_TIMEOUT = 30

@inline function _resolve_connect_timeout(client::Union{Nothing,Client}, value::Union{Nothing,Real})::Real
    if value === nothing
        client === nothing && return _DEFAULT_CONNECT_TIMEOUT
        default = client.default_connect_timeout
        return default > 0 ? default : _DEFAULT_CONNECT_TIMEOUT
    end
    return _client_default_timeout(client, value, :default_connect_timeout)
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
    max_decompressed_size::Integer=_DEFAULT_MAX_DECOMPRESSED_SIZE,
    sse_callback=nothing,
    max_sse_line_bytes::Integer=_DEFAULT_SSE_CLIENT_MAX_LINE_BYTES,
    max_sse_event_bytes::Integer=_DEFAULT_SSE_CLIENT_MAX_EVENT_BYTES,
    client::Union{Nothing,Client}=nothing,
    context::Union{Nothing,RequestContext}=nothing,
    connect_timeout::Union{Nothing,Real}=nothing,
    request_timeout::Real=0,
    response_header_timeout::Real=0,
    read_idle_timeout::Real=0,
    write_idle_timeout::Real=0,
    expect_continue_timeout=nothing,
    readtimeout=nothing,
    copyheaders::Bool=true,
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
            detect_content_type=detect_content_type,
            observelayers=observelayers,
            retry_delays=retry_delays,
            retry_check=retry_check,
            sslconfig=sslconfig,
            socket_type_tls=socket_type_tls,
            logerrors=logerrors,
            logtag=logtag,
        )
        max_decompressed_size >= 0 || throw(ArgumentError("max_decompressed_size must be >= 0"))
        max_sse_line_bytes >= 0 || throw(ArgumentError("max_sse_line_bytes must be >= 0"))
        max_sse_event_bytes >= 0 || throw(ArgumentError("max_sse_event_bytes must be >= 0"))
        # Merge per-call values with client defaults (per-call wins)
        connect_timeout = _resolve_connect_timeout(client, connect_timeout)
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
        req_headers = _normalize_headers_input(headers, copyheaders)
        _apply_client_default_headers!(req_headers, client)
        canonicalize_headers === true && _canonicalize_header_names!(req_headers)
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
            copyheaders=false,
            body=normalized_body.body,
            host=parsed.host_header,
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
                nothing,
                protocol,
                _redirect_policy(req_client, redirect ? redirect_limit : 0, redirect_method, forwardheaders),
                retry_controller,
                proxy_config,
                normalized_cookies,
                effective_cookiejar;
                copyrequest=false,
            )
            incoming = incoming_response::_IncomingResponse
            resolved_request = incoming.head.request === nothing ? req : incoming.head.request::Request
            if sse_callback !== nothing
                sse_response = _finalize_request_response(incoming, nobody, Int64(0), resolved_request, parsed.url)
                if !_status_throws(sse_response)
                    _consume_incoming_sse!(
                        incoming,
                        sse_response,
                        sse_callback::Function,
                        decompress,
                        Int(max_sse_line_bytes),
                        Int(max_sse_event_bytes),
                    )
                    final_response = sse_response
                    return sse_response
                end
            end
            final_body, final_length = if sink isa AbstractVector{UInt8} && incoming.head.status >= 300
                # Only a 2xx body goes into a byte buffer, so an error or an
                # unfollowed redirect can't overflow or overwrite it.
                limit = max_decompressed_size > 0 ? min(_MAX_NON_2XX_BODY_BYTES, Int(max_decompressed_size)) : _MAX_NON_2XX_BODY_BYTES
                prefix = _read_response_prefix(incoming, decompress, limit)
                prefix, Int64(length(prefix))
            else
                _consume_incoming_response!(incoming, sink, decompress, Int(max_decompressed_size))
            end
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
        wrapped = err isa Exception ? _wrap_client_transport_error(err::Exception, "request", request_timeout_ns, elapsed_ns) : err
        final_error = wrapped::Exception
        wrapped === err ? rethrow() : throw(wrapped)
    finally
        _emit_trace(trace, DoneEvent(final_response, final_error, request_url === nothing ? _url_for_message(String(url)) : request_url::String))
    end
end

"""
    request(method, url, headers=[], body=nothing; kwargs...) -> Response
    request(trace, method, url, headers=[], body=nothing; kwargs...) -> Response

Send an HTTP request and return the [`Response`](@ref), with the whole body in
`response.body` as a `Vector{UInt8}`.

`url` is a string or `URI`. `headers` is anything [`Headers`](@ref) accepts.
`body` may be a `String`, a byte vector, an `IO`, a `Dict` or `NamedTuple` (sent
as a URL-encoded form), a [`Form`](@ref), an iterable of string or byte chunks,
or an [`AbstractBody`](@ref). `headers` and `body` can also be passed as
keywords. Unless the request sets them, HTTP.jl sends
`User-Agent: HTTP.jl/<version>` and `Accept-Encoding: gzip, deflate`.

A response with status 300 or above throws a [`StatusError`](@ref), except for
redirect responses (301, 302, 303, 307, and 308). A timeout throws a
[`TimeoutError`](@ref), and a failure to connect throws an error such as
[`ConnectError`](@ref) or [`DNSError`](@ref).

!!! warning "`String(response.body)` empties `response.body`"
    `String(::Vector{UInt8})` takes over the vector's memory instead of copying
    it, so `response.body` is empty afterwards. Use `String(copy(response.body))`
    if you need the bytes again.

# Keywords

Request and response:
- `query`: a `Dict`, `NamedTuple`, vector of pairs, or string to add to the
  URL's query string.
- `basicauth`: credentials as `user => password` or `(user, password)`. An
  `Authorization` header takes precedence; credentials in the URL are used when
  neither is given. In a URL, percent-encode characters such as `/`, `?`, `#`,
  space, and `\`, as in `https://user:p%2Fss@host/`.
- `status_exception = true`: throw `StatusError` for a failing response.
- `response_stream`: an `IO` or byte vector that receives the body instead of
  `response.body`, which is then `nothing` for an `IO` and the filled vector or
  view otherwise. A byte vector must be large enough for the body, and is
  resized to it if it is a `Vector{UInt8}`. A response with status 300 or
  above, including a redirect that is not followed, leaves a byte vector
  untouched and puts up to 1 MiB of its body (or `max_decompressed_size`, if
  smaller) in `response.body`.
- `decompress = true`: decompress gzip and deflate responses. `false` returns
  the body as sent and does not send `Accept-Encoding`.
- `max_decompressed_size = 64 MiB`: the largest decompressed body; a larger one
  throws `DecompressionLimitError`. `0` means no limit.
- `sse_callback`: for a server-sent event stream, call `f(event)` or
  `f(stream, event)` with each [`SSEEvent`](@ref) instead of reading the body.
  `max_sse_line_bytes = 1 MiB` and `max_sse_event_bytes = 16 MiB` limit the
  size of a line and an event; `0` means no limit.
- `copyheaders = true`: `false` lets the request use an `HTTP.Headers`
  collection without copying it. Do not touch it until the call returns; its
  contents afterwards are unspecified.
- `canonicalize_headers = false`: `true` sends header names in
  [`canonical_header_key`](@ref) form. Otherwise names are sent as given, and
  HTTP/2 sends them in lowercase.

Redirects:
- `redirect = true`: follow redirects.
- `redirect_limit`: the most redirects to follow; defaults to the client's
  `max_redirects`, 10 by default. With `0`, the redirect response is returned.
- `redirect_method`: the method for following a 301 or 302 redirect, or
  `:same` to keep the original method. By default `GET` is used, except that
  `HEAD` and `QUERY` are kept. A 303 always uses `GET`, and 307 and 308 keep the
  method.
- `forwardheaders = true`: send the request's headers again when following a
  redirect. `Authorization`, `Cookie`, and `Proxy-Authorization` are dropped when
  the redirect goes to another origin; other headers, such as `X-Api-Key`, are
  sent there too.

Retries (see the client guide for the default rules):
- `retry = true`: retry failed attempts. An idempotent request that fails on a
  reused connection the server already closed is resent either way.
- `retries = 4`: the most retries after the first attempt.
- `retry_non_idempotent = false`: also retry methods other than `GET`, `HEAD`,
  `OPTIONS`, `TRACE`, `QUERY`, `PUT`, and `DELETE`.
- `retry_if`: a function `(attempt, err, req, resp)` that returns `true` to
  retry, `false` to stop, or `nothing` for the default rules. For a failure
  without a response, `err` is a [`RequestRetryError`](@ref) and `resp` is
  `nothing`; for a response, `err` is `nothing`. A body that cannot be sent again
  is never retried.
- `respect_retry_after = true`: wait as long as a 429 or 503 response's
  `Retry-After` header asks.
- `retry_bucket = true`: use the transport's [`RetryBucket`](@ref) to limit
  retries; pass `false` to skip it, or another `RetryBucket`.

Timeouts, in seconds:
- `connect_timeout`: DNS lookup, TCP connect, proxy handshake, TLS handshake,
  and HTTP/2 setup. Defaults to the client's `connect_timeout`, or 30.
- `request_timeout`: the whole call.
- `response_header_timeout`: the wait for the response headers.
- `read_idle_timeout`: the time between reads, including the wait for the
  response headers.
- `write_idle_timeout`: the time between writes.
- `expect_continue_timeout`: how long a request with an
  `Expect: 100-continue` header waits for `100 Continue` before it sends the
  body anyway, 1 second by default. `0` sends the body without waiting.
- `context`: a [`RequestContext`](@ref) for cancellation and an absolute
  deadline.

Connections:
- `client`: the [`Client`](@ref) to use; defaults to a shared client.
- `proxy`: a proxy URL, a [`ProxyConfig`](@ref), or `nothing` to connect
  directly. Cannot be combined with `client`; set the proxy on its `Transport`.
- `cookies = true`: send and store cookies with the cookie jar. `false` turns
  cookies off, and a `Dict` adds name/value pairs. Cookies from the jar are
  merged into a `Cookie` header set on the request.
- `cookiejar`: the [`CookieJar`](@ref) to use; defaults to the client's jar, or
  `HTTP.COOKIEJAR` for calls without a client.
- `require_ssl_verification = true`: `false` skips certificate checks, for
  testing only. Cannot be combined with `client`.
- `protocol = :auto`: `:h1` or `:h2` to force HTTP/1.1 or HTTP/2.

Debugging:
- `verbose`: `1` (or `true`) prints a line for each attempt, response, retry,
  redirect, and the result; `2` also prints the request and response heads.
- `trace`: a function called with each [`RequestEvent`](@ref),
  [`ResponseHeadEvent`](@ref), [`RetryEvent`](@ref),
  [`RetrySkippedEvent`](@ref), [`RedirectEvent`](@ref), and
  [`DoneEvent`](@ref).

# Extended help

These HTTP.jl 1.x keywords are accepted but have no effect, and log a warning:
`pool`, `retry_delays`, `retry_check`, `sslconfig`, `socket_type_tls`,
`detect_content_type`, `observelayers`, `logerrors`, and `logtag`. The
deprecated `readtimeout` sets `read_idle_timeout`.
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
    get(url, headers=[]; kwargs...) -> Response
    head(url, headers=[]; kwargs...) -> Response
    options(url, headers=[]; kwargs...) -> Response
    post(url, [headers], [body]; kwargs...) -> Response
    put(url, [headers], [body]; kwargs...) -> Response
    patch(url, [headers], [body]; kwargs...) -> Response
    delete(url, [headers], [body]; kwargs...) -> Response
    query(url, [headers], [body]; kwargs...) -> Response

Send a request with the method in the function's name: `HTTP.get(url)` is
`HTTP.request("GET", url)`. Each takes the keywords of [`request`](@ref),
including `headers` and `body`, and also accepts a [`Client`](@ref) as its first
argument.
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
function query(url::Union{AbstractString,URI}, args...; kwargs...)
    headers, body = _split_headers_body_args(args)
    return request("QUERY", url, headers, body; kwargs...)
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

function query(client::Client, url::Union{AbstractString,URI}, args...; kwargs...)
    headers, body = _split_headers_body_args(args)
    return request("QUERY", url, headers, body; client=client, kwargs...)
end

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

Define `request`, the verb helpers (`get`, `post`, ...), and `open` in the
calling module so that they pass through middleware before reaching HTTP.jl.

A middleware is a function `mw(next) -> f`. Request middleware returns
`f(method, url, headers, body; kwargs...)`, which handles `request` and the verb
helpers. Stream middleware returns `f(method, url, headers; kwargs...)`, which
handles `open`. Each position takes one middleware or a tuple of them; in
`(outer, inner)`, `outer` runs first.
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

        function query(url, args...; kwargs...)
            $__source__
            headers, body = HTTP._split_headers_body_args(args)
            return request("QUERY", url, headers, body; kwargs...)
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
