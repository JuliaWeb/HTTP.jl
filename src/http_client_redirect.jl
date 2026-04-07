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
    method in ("GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH") || throw(ArgumentError("redirect_method must be one of GET, POST, PUT, DELETE, HEAD, OPTIONS, PATCH, or :same"))
    return method, false
end

function _is_redirect_status(status::Int)::Bool
    return status == 301 || status == 302 || status == 303 || status == 307 || status == 308
end

function _split_request_target(target::String)::Tuple{String,String}
    current = isempty(target) ? "/" : target
    hash_idx = findfirst('#', current)
    hash_idx === nothing || (current = String(SubString(current, firstindex(current), prevind(current, hash_idx))))
    query_idx = findfirst('?', current)
    if query_idx === nothing
        return isempty(current) ? "/" : current, ""
    end
    path = query_idx == firstindex(current) ? "/" : String(SubString(current, firstindex(current), prevind(current, query_idx)))
    query = query_idx == lastindex(current) ? "" : String(SubString(current, nextind(current, query_idx), lastindex(current)))
    return isempty(path) ? "/" : path, query
end

function _join_request_target(path::String, query::String)::String
    final_path = isempty(path) ? "/" : path
    isempty(query) && return final_path
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
    absolute = startswith(path, "/")
    trailing_slash = endswith(path, "/") || endswith(path, "/.") || endswith(path, "/..")
    segments = split(path, '/'; keepempty=false)
    stack = String[]
    for segment in segments
        if segment == "."
            continue
        elseif segment == ".."
            isempty(stack) || pop!(stack)
        else
            push!(stack, segment)
        end
    end
    normalized = absolute ? "/" : ""
    normalized *= join(stack, "/")
    isempty(normalized) && return absolute ? "/" : "."
    if trailing_slash && normalized != "/"
        normalized *= "/"
    end
    return normalized
end

function _resolve_relative_redirect_request_target(current_target::String, location::String)::String
    base_path, base_query = _split_request_target(current_target)
    startswith(location, "#") && return _join_request_target(base_path, base_query)
    startswith(location, "?") && return _join_request_target(base_path, String(SubString(location, nextind(location, firstindex(location)), lastindex(location))))
    reference = location
    hash_idx = findfirst('#', reference)
    hash_idx === nothing || (reference = String(SubString(reference, firstindex(reference), prevind(reference, hash_idx))))
    query = ""
    query_idx = findfirst('?', reference)
    if query_idx !== nothing
        query = query_idx == lastindex(reference) ? "" : String(SubString(reference, nextind(reference, query_idx), lastindex(reference)))
        reference = query_idx == firstindex(reference) ? "" : String(SubString(reference, firstindex(reference), prevind(reference, query_idx)))
    end
    if isempty(reference)
        return _join_request_target(base_path, query_idx === nothing ? base_query : query)
    end
    path = if startswith(reference, "/")
        _remove_dot_segments(reference)
    else
        _remove_dot_segments(_merge_redirect_base_path(base_path, reference))
    end
    return _join_request_target(path, query)
end

@inline function _normalize_redirect_host(host::String)::String
    normalized = lowercase(host)
    while !isempty(normalized) && last(normalized) == '.'
        normalized = normalized[1:prevind(normalized, lastindex(normalized))]
    end
    return normalized
end

function _is_domain_or_subdomain(sub::String, parent::String)::Bool
    sub == parent && return true
    (occursin(':', sub) || occursin('%', sub)) && return false
    return endswith(sub, "." * parent)
end

function _should_copy_sensitive_headers_on_redirect(initial_address::String, redirect_address::String)::Bool
    initial_host = try
        HostResolvers.split_host_port(initial_address)[1]
    catch
        initial_address
    end
    redirect_host = try
        HostResolvers.split_host_port(redirect_address)[1]
    catch
        redirect_address
    end
    initial_norm = _normalize_redirect_host(initial_host)
    redirect_norm = _normalize_redirect_host(redirect_host)
    isempty(initial_norm) && return false
    isempty(redirect_norm) && return false
    return _is_domain_or_subdomain(redirect_norm, initial_norm)
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

function _normalize_redirect_authority(authority::String, secure::Bool)::String
    at_idx = _find_last_ascii_delim(authority, UInt8('@'))
    if at_idx != 0
        authority = String(SubString(authority, nextind(authority, at_idx), lastindex(authority)))
    end
    isempty(authority) && throw(ProtocolError("redirect location is missing host"))
    if startswith(authority, "[")
        if occursin("]:", authority)
            return authority
        end
        close_idx = findfirst(']', authority)
        close_idx === nothing && throw(ProtocolError("invalid IPv6 host authority in redirect location: $authority"))
        host = String(SubString(authority, nextind(authority, firstindex(authority)), prevind(authority, close_idx)))
        return HostResolvers.join_host_port(host, secure ? 443 : 80)
    end
    colon_count = count(==(':'), authority)
    if colon_count == 0
        return HostResolvers.join_host_port(authority, secure ? 443 : 80)
    end
    if colon_count == 1
        return authority
    end
    return HostResolvers.join_host_port(authority, secure ? 443 : 80)
end

function _resolve_redirect_target(current_address::String, current_secure::Bool, location::String, current_target::String)
    scheme_match = match(r"^([A-Za-z][A-Za-z0-9+\\.-]*):", location)
    if scheme_match !== nothing
        scheme = lowercase(String(scheme_match.captures[1]))
        (scheme == "http" || scheme == "https") || throw(ProtocolError("unsupported redirect location scheme '$scheme'"))
        parsed = _parse_http_url(location)
        return parsed.address, parsed.secure, parsed.target
    end
    if startswith(location, "//")
        parsed = _parse_http_url(string(current_secure ? "https:" : "http:", location))
        return parsed.address, parsed.secure, parsed.target
    end
    return current_address, current_secure, _resolve_relative_redirect_request_target(current_target, location)
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
    method == "HEAD" && return method
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
            request.context,
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
