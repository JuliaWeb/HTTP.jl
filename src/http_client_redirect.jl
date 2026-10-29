# HTTP client redirect policy, target resolution, and redirect request rewriting.
struct _RedirectPolicy{CR}
    check_redirect::CR
    max_redirects::Int
    redirect_method::Union{Nothing,String}
    preserve_method::Bool
    forward_headers::Bool
end

@inline _call_check_redirect(::Nothing, response::Response, request::Request, location::String)::Bool = true

@inline function _call_check_redirect(check_redirect, response::Response, request::Request, location::String)::Bool
    proceed = check_redirect(response, request, location)
    proceed isa Bool || throw(ProtocolError("check_redirect callback must return Bool"))
    return proceed
end

function _normalize_redirect_method_override(redirect_method)::Tuple{Union{Nothing,String},Bool}
    redirect_method === nothing && return nothing, false
    redirect_method == :same && return nothing, true
    redirect_method isa AbstractString || redirect_method isa Symbol || throw(ArgumentError("redirect_method must be nothing, :same, or an HTTP method String/Symbol"))
    method = uppercase(String(redirect_method))
    method in ("GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH", "QUERY") || throw(ArgumentError("redirect_method must be one of GET, POST, PUT, DELETE, HEAD, OPTIONS, PATCH, QUERY, or :same"))
    return method, false
end

function _is_redirect_status(status::Int)::Bool
    return status == 301 || status == 302 || status == 303 || status == 307 || status == 308
end

function _split_request_target(target::String)::Tuple{String,Union{Nothing,String}}
    # An absent query may be inherited; an explicitly empty query must replace it.
    current = target
    hash_idx = findfirst('#', current)
    hash_idx === nothing || (current = String(SubString(current, firstindex(current), prevind(current, hash_idx))))
    query_idx = findfirst('?', current)
    if query_idx === nothing
        return current, nothing
    end
    path = query_idx == firstindex(current) ? "" : String(SubString(current, firstindex(current), prevind(current, query_idx)))
    query = query_idx == lastindex(current) ? "" : String(SubString(current, nextind(current, query_idx), lastindex(current)))
    return path, query
end

function _join_request_target(path::String, query::Union{Nothing,String})::String
    final_path = isempty(path) ? "/" : path
    query === nothing && return final_path
    return string(final_path, "?", query)
end

@inline function _find_last_ascii_delim(s::String, delim::UInt8)::Int
    bytes = codeunits(s)
    for i in length(bytes):-1:1
        @inbounds bytes[i] == delim && return i
    end
    return 0
end

function _merge_redirect_base_path(base_path::String, relative_path::String)::String
    isempty(relative_path) && return base_path
    slash = _find_last_ascii_delim(base_path, UInt8('/'))
    slash == 0 && return "/" * relative_path
    return string(SubString(base_path, firstindex(base_path), slash), relative_path)
end

function _remove_dot_segments(path::String)::String
    occursin('.', path) || return path
    absolute = startswith(path, "/")
    terminal_dot = endswith(path, "/.") || endswith(path, "/..")
    stack = SubString{String}[]
    for (i, segment) in enumerate(eachsplit(path, '/'; keepempty=true))
        i == 1 && absolute && continue
        if segment == "."
            continue
        elseif segment == ".."
            if !isempty(stack)
                pop!(stack)
                # Removing the first segment also leaves the following slash.
                isempty(stack) && (absolute = true)
            end
        else
            push!(stack, segment)
        end
    end
    normalized = (absolute ? "/" : "") * join(stack, "/")
    if terminal_dot && !isempty(stack)
        normalized *= "/"
    end
    return normalized
end

function _resolve_relative_redirect_request_target(current_target::String, location::String)::String
    base_path, base_query = _split_request_target(current_target)
    reference, query = _split_request_target(location)
    if isempty(reference)
        return _join_request_target(base_path, query === nothing ? base_query : query)
    end
    path = if startswith(reference, "/")
        _remove_dot_segments(reference)
    else
        _remove_dot_segments(_merge_redirect_base_path(base_path, reference))
    end
    return _join_request_target(path, query)
end

@inline function _normalize_redirect_host(host::String)::String
    normalized = _fast_lowercase(host)
    while !isempty(normalized) && last(normalized) == '.'
        normalized = normalized[1:prevind(normalized, lastindex(normalized))]
    end
    return normalized
end

@inline function _split_redirect_host_port(address::String)::Tuple{String,String}
    return try
        host, port = HostResolvers.split_host_port(address)
        (host, port)
    catch
        # `address` has no explicit port; treat the whole value as the host and
        # leave the port unknown so the caller can fall back to the scheme port.
        (address, "")
    end
end

# Keep credential headers (those `_strip_sensitive_redirect_headers!` removes)
# only when the redirect stays on the same origin: scheme, port, and normalized
# host all match. Unlike Go's net/http, subdomains are not trusted; the cookie
# jar handles domain-scoped cookies. A scheme or port change can reach another
# service (cf. curl CVE-2022-27776, python-requests CVE-2018-18074).
function _should_copy_sensitive_headers_on_redirect(
    initial_address::String,
    redirect_address::String,
    initial_secure::Bool,
    redirect_secure::Bool,
)::Bool
    # A scheme change (in particular an https->http downgrade) always crosses a
    # security boundary, so never carry credentials across it.
    initial_secure == redirect_secure || return false
    initial_host, initial_port = _split_redirect_host_port(initial_address)
    redirect_host, redirect_port = _split_redirect_host_port(redirect_address)
    # Resolve missing ports to the scheme default so that e.g. `host` and
    # `host:443` over https compare equal, while a genuine port change is caught.
    initial_port = isempty(initial_port) ? (initial_secure ? "443" : "80") : initial_port
    redirect_port = isempty(redirect_port) ? (redirect_secure ? "443" : "80") : redirect_port
    # A port change (e.g. :443 -> :8443) reaches a different service; strip.
    initial_port == redirect_port || return false
    initial_norm = _normalize_redirect_host(initial_host)
    redirect_norm = _normalize_redirect_host(redirect_host)
    isempty(initial_norm) && return false
    isempty(redirect_norm) && return false
    return redirect_norm == initial_norm
end

function _strip_sensitive_redirect_headers!(headers::Headers)
    removeheader(headers, "Authorization")
    removeheader(headers, "Www-Authenticate")
    removeheader(headers, "Cookie")
    removeheader(headers, "Cookie2")
    removeheader(headers, "Proxy-Authorization")
    removeheader(headers, "Proxy-Authenticate")
    return nothing
end

# Returns `(address, secure, target, host_header)` for the next hop. `address`
# is the dial target and always has a port; `host_header` is the `Host` value
# as written in the Location (see `_urlparts_host_header!`). A relative redirect
# keeps the current host: `current_host_header` (the hop's `request.host`), or
# `address` when that is `nothing` (`do!` callers that set `Host` only in the
# headers, which `_prepare_request_for_redirect` strips).
function _resolve_redirect_target(current_address::String, current_secure::Bool, location::String, current_target::String, current_host_header::Union{Nothing,String})
    scheme_match = match(r"^([A-Za-z][A-Za-z0-9+\\.-]*):", location)
    if scheme_match !== nothing
        scheme = lowercase(String(scheme_match.captures[1]))
        (scheme == "http" || scheme == "https") || throw(ProtocolError("unsupported redirect location scheme '$scheme'"))
        # Strict RFC 3986 §5.2.2 parsing, as in Go and curl: `http:g` is an
        # absolute URL without a host, not the relative reference `g`.
        url = location
    elseif startswith(location, "//")
        url = string(current_secure ? "https:" : "http:", location)
    else
        next_host_header = current_host_header === nothing ? current_address : current_host_header
        target = _resolve_relative_redirect_request_target(current_target, _escape_target_spaces(location))
        return current_address, current_secure, target, next_host_header
    end
    # A Location that is not an http(s) URL with a host is the server's error.
    parsed = try
        _parse_http_url(url)
    catch err
        err isa ArgumentError || rethrow()
        throw(ProtocolError(string("invalid redirect location: ", location), err))
    end
    target = _resolve_relative_redirect_request_target("/", parsed.target)
    return parsed.address, parsed.secure, target, parsed.host_header
end

function _rewrite_method_for_redirect(method::String, status::Int, policy::_RedirectPolicy)::String
    if status == 307 || status == 308
        return method
    end
    if status == 303
        return "GET"
    end
    if policy.preserve_method
        return method
    end
    if policy.redirect_method !== nothing
        return policy.redirect_method::String
    end
    (method == "HEAD" || method == "QUERY") && return method
    return "GET"
end

@inline function _redirect_body_replayable(request::Request)::Bool
    request.content_length == 0 && return true
    request.body isa EmptyBody && return true
    request.body isa BytesBody && return true
    return false
end

@inline function _redirect_reuses_request_body(method::String)::Bool
    return !(method == "GET" || method == "HEAD")
end

function _redirect_referer(
    last_secure::Bool,
    last_address::String,
    last_target::String,
    new_secure::Bool,
    explicit_ref::Union{Nothing,String},
)::Union{Nothing,String}
    if last_secure && !new_secure
        return nothing
    end
    if explicit_ref !== nothing && !isempty(explicit_ref::String)
        return explicit_ref::String
    end
    target = isempty(last_target) ? "/" : last_target
    startswith(target, "/") || (target = "/" * target)
    return string(last_secure ? "https://" : "http://", last_address, target)
end

function _prepare_request_for_redirect(request::Request, status::Int, new_target::String, policy::_RedirectPolicy)::Request
    method = _rewrite_method_for_redirect(request.method, status, policy)
    if method == request.method
        copied = _copy_request(request)
        copied.target = new_target
        if !policy.forward_headers
            copied.headers = Headers()
            copied.trailers = Headers()
        end
        removeheader(copied.headers, "Host")
        return copied
    end
    redirected = if _redirect_reuses_request_body(method)
        copied = _copy_request(request)
        copied.method = method
        copied.target = new_target
        if !policy.forward_headers
            copied.headers = Headers()
            copied.trailers = Headers()
        end
        copied
    else
        _request_nocopy(
            method,
            new_target,
            policy.forward_headers ? copy(request.headers) : Headers(),
            Headers(),
            EmptyBody(),
            request.host,
            Int64(0),
            request.proto_major,
            request.proto_minor,
            request.close,
            get_request_context(request),
        )
    end
    removeheader(redirected.headers, "Host")
    if !_redirect_reuses_request_body(method)
        # When a redirect rewrites the method to GET/HEAD, entity headers tied
        # to the old request body must be removed.
        removeheader(redirected.headers, "Content-Length")
        removeheader(redirected.headers, "Transfer-Encoding")
        removeheader(redirected.headers, "Content-Type")
        removeheader(redirected.headers, "Content-Encoding")
        removeheader(redirected.headers, "Content-Language")
        removeheader(redirected.headers, "Content-Location")
    end
    return redirected
end
