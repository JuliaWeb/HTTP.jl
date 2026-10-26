# Alt-Svc (RFC 7838): how an https origin advertises HTTP/3. The client
# records each origin's HTTP/3 alternative from the `Alt-Svc` response
# header, for as long as its `ma` (max-age) allows, and stops using an
# alternative for a while once connecting to it fails.

struct _AltSvcEntry
    protocol::String
    # Empty for the origin's own host.
    host::String
    port::Int
    max_age_s::Int64
end

const _ALT_SVC_DEFAULT_MAX_AGE_S = Int64(86400)
# How long an alternative that failed to connect is left unused.
const _ALT_SVC_BROKEN_NS = Int64(300) * 1_000_000_000

# Splits `s` at `sep` outside quoted strings.
function _alt_svc_split(s::AbstractString, sep::Char)::Vector{String}
    parts = String[]
    buf = IOBuffer()
    quoted = false
    escaped = false
    for c in s
        if escaped
            write(buf, c)
            escaped = false
        elseif quoted && c == '\\'
            write(buf, c)
            escaped = true
        elseif c == '"'
            write(buf, c)
            quoted = !quoted
        elseif c == sep && !quoted
            push!(parts, String(take!(buf)))
        else
            write(buf, c)
        end
    end
    push!(parts, String(take!(buf)))
    return parts
end

function _alt_svc_unquote(s::AbstractString)::Union{Nothing,String}
    (length(s) >= 2 && startswith(s, '"') && endswith(s, '"')) || return nothing
    out = IOBuffer()
    escaped = false
    for c in SubString(s, nextind(s, firstindex(s)), prevind(s, lastindex(s)))
        if escaped
            write(out, c)
            escaped = false
        elseif c == '\\'
            escaped = true
        else
            write(out, c)
        end
    end
    return String(take!(out))
end

function _alt_svc_percent_decode(s::AbstractString)::Union{Nothing,String}
    occursin('%', s) || return String(s)
    bytes = codeunits(s)
    out = UInt8[]
    i = 1
    while i <= length(bytes)
        b = bytes[i]
        if b == UInt8('%')
            i + 2 <= length(bytes) || return nothing
            v = tryparse(UInt8, String(bytes[(i + 1):(i + 2)]); base=16)
            v === nothing && return nothing
            push!(out, v)
            i += 3
        else
            push!(out, b)
            i += 1
        end
    end
    return String(out)
end

# One alternative, `protocol-id="[host]:port"` followed by parameters.
function _alt_svc_parse_alternative(value::AbstractString)::Union{Nothing,_AltSvcEntry}
    parts = _alt_svc_split(value, ';')
    alternative = strip(parts[1])
    eq = findfirst('=', alternative)
    eq === nothing && return nothing
    protocol = _alt_svc_percent_decode(strip(alternative[1:prevind(alternative, eq)]))
    (protocol === nothing || isempty(protocol)) && return nothing
    authority = _alt_svc_unquote(strip(alternative[nextind(alternative, eq):end]))
    authority === nothing && return nothing
    # The port follows the last colon; an IPv6 host has colons of its own.
    colon = 0
    for (i, c) in pairs(authority)
        c == ':' && (colon = i)
    end
    colon == 0 && return nothing
    host = authority[1:prevind(authority, colon)]
    if startswith(host, '[') && endswith(host, ']')
        host = host[2:prevind(host, lastindex(host))]
    end
    port = tryparse(Int, authority[nextind(authority, colon):end])
    (port === nothing || !(1 <= port <= 65535)) && return nothing
    max_age = _ALT_SVC_DEFAULT_MAX_AGE_S
    for param in @view parts[2:end]
        peq = findfirst('=', param)
        peq === nothing && continue
        name = lowercase(strip(param[1:prevind(param, peq)]))
        name == "ma" || continue
        raw = strip(param[nextind(param, peq):end])
        unquoted = startswith(raw, '"') ? _alt_svc_unquote(raw) : String(raw)
        parsed = unquoted === nothing ? nothing : tryparse(Int64, unquoted)
        parsed !== nothing && parsed >= 0 && (max_age = parsed)
    end
    return _AltSvcEntry(protocol, String(host), port, max_age)
end

"""
    _parse_alt_svc(value) -> Vector{_AltSvcEntry} or :clear

Parse one `Alt-Svc` header value (RFC 7838 Section 3), skipping malformed
alternatives.
"""
function _parse_alt_svc(value::AbstractString)::Union{Symbol,Vector{_AltSvcEntry}}
    strip(value) == "clear" && return :clear
    entries = _AltSvcEntry[]
    for part in _alt_svc_split(value, ',')
        isempty(strip(part)) && continue
        entry = _alt_svc_parse_alternative(part)
        entry === nothing || push!(entries, entry)
    end
    return entries
end

"""
    _AltSvcCache

The HTTP/3 alternative of each https origin (`"host:port"`): where to
connect, and until when. Thread-safe.
"""
mutable struct _AltSvcCache
    lock::ReentrantLock
    entries::Dict{String,Tuple{String,Int64}}
    broken::Dict{String,Int64}
end

_AltSvcCache() = _AltSvcCache(ReentrantLock(), Dict{String,Tuple{String,Int64}}(), Dict{String,Int64}())

function _alt_svc_saturating_deadline(now_ns::Int64, seconds::Int64)::Int64
    seconds >= typemax(Int64) ÷ 1_000_000_000 && return typemax(Int64)
    ns = seconds * 1_000_000_000
    return now_ns > typemax(Int64) - ns ? typemax(Int64) : now_ns + ns
end

"""
    _alt_svc_record!(cache, origin, values, now_ns)

Update `origin`'s entry from the `Alt-Svc` header `values` of one of its
responses: the first `h3` alternative replaces it, and `clear` removes it.
"""
function _alt_svc_record!(cache::_AltSvcCache, origin::String, values::Vector{String}, now_ns::Int64)::Nothing
    origin_host, _ = HostResolvers.split_host_port(origin)
    chosen = nothing
    cleared = false
    for value in values
        parsed = _parse_alt_svc(value)
        if parsed === :clear
            cleared = true
            continue
        end
        for entry in parsed::Vector{_AltSvcEntry}
            entry.protocol == "h3" || continue
            chosen = entry
            break
        end
        chosen === nothing || break
    end
    lock(cache.lock)
    try
        if chosen !== nothing
            e = chosen::_AltSvcEntry
            host = isempty(e.host) ? origin_host : e.host
            cache.entries[origin] = (HostResolvers.join_host_port(host, string(e.port)), _alt_svc_saturating_deadline(now_ns, e.max_age_s))
        elseif cleared
            delete!(cache.entries, origin)
        end
    finally
        unlock(cache.lock)
    end
    return nothing
end

"""
    _alt_svc_lookup(cache, origin, now_ns) -> "host:port" or nothing

Where to connect for HTTP/3 to `origin`, if it advertised a fresh
alternative that has not recently failed.
"""
function _alt_svc_lookup(cache::_AltSvcCache, origin::String, now_ns::Int64)::Union{Nothing,String}
    lock(cache.lock)
    try
        _alt_svc_broken_locked(cache, origin, now_ns) && return nothing
        entry = get(cache.entries, origin, nothing)
        entry === nothing && return nothing
        address, expires = entry
        if now_ns >= expires
            delete!(cache.entries, origin)
            return nothing
        end
        return address
    finally
        unlock(cache.lock)
    end
end

function _alt_svc_broken_locked(cache::_AltSvcCache, origin::String, now_ns::Int64)::Bool
    until = get(cache.broken, origin, nothing)
    until === nothing && return false
    now_ns < until && return true
    delete!(cache.broken, origin)
    return false
end

_alt_svc_broken(cache::_AltSvcCache, origin::String, now_ns::Int64)::Bool =
    lock(() -> _alt_svc_broken_locked(cache, origin, now_ns), cache.lock)

"Stop using `origin`'s HTTP/3 alternative for `_ALT_SVC_BROKEN_NS`."
function _alt_svc_mark_broken!(cache::_AltSvcCache, origin::String, now_ns::Int64)::Nothing
    lock(cache.lock)
    try
        delete!(cache.entries, origin)
        cache.broken[origin] = now_ns + _ALT_SVC_BROKEN_NS
    finally
        unlock(cache.lock)
    end
    return nothing
end

function _alt_svc_clear!(cache::_AltSvcCache)::Nothing
    lock(cache.lock)
    try
        empty!(cache.entries)
        empty!(cache.broken)
    finally
        unlock(cache.lock)
    end
    return nothing
end
