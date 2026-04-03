# Core HTTP request/response/header/body types and errors.
using Reseau.TCP
using Reseau.TLS

export Headers
export Request
export Response
export RequestContext
export AbstractBody
export EmptyBody
export BytesBody
export CallbackBody
export nobody
export ParseError
export ProtocolError
export CanceledError
export HTTPTimeoutError
export canonical_header_key
export header
export headers
export hasheader
export headercontains
export setheader
export defaultheader!
export appendheader
export removeheader
export mkheaders
export body_read!
export body_close!
export body_closed
export set_deadline!
export cancel!
export canceled
export expired

"""
    ParseError

Raised when byte-level HTTP syntax cannot be parsed. This is used for malformed
request/status lines, invalid header syntax, truncated framed bodies, and other
wire-format failures where the peer did not send valid HTTP.
"""
struct ParseError <: Exception
    message::String
end

@enum _ProtocolErrorCode::UInt8 begin
    _PROTOCOL_ERROR_GENERIC = 0
    _PROTOCOL_ERROR_LINE_TOO_LONG = 1
    _PROTOCOL_ERROR_HEADERS_TOO_LARGE = 2
end

"""
    ProtocolError

Raised when the bytes are syntactically valid but violate higher-level HTTP
rules. Examples include mismatched `Content-Length` values, impossible frame
ordering, or unsupported control-flow states in the client/server stacks.
"""
struct ProtocolError <: Exception
    message::String
    code::_ProtocolErrorCode
    err::Union{Nothing,Exception}
end

ProtocolError(message::AbstractString) = ProtocolError(String(message), _PROTOCOL_ERROR_GENERIC, nothing)
ProtocolError(message::AbstractString, code::_ProtocolErrorCode) = ProtocolError(String(message), code, nothing)
ProtocolError(message::String, err::Exception) = invoke(ProtocolError, Tuple{String, _ProtocolErrorCode, Union{Nothing,Exception}}, message, _PROTOCOL_ERROR_GENERIC, err)
ProtocolError(message::AbstractString, err::Exception) = ProtocolError(String(message), err::Exception)
ProtocolError(message::AbstractString, code::_ProtocolErrorCode, err::Exception) = ProtocolError(String(message), code, err)

"""
    CanceledError

Raised when request processing is canceled explicitly through `RequestContext`.
Unlike `ParseError` and `ProtocolError`, this usually reflects local control
flow rather than a bad peer.
"""
struct CanceledError <: Exception
    message::String
end

"""
    HTTPTimeoutError

Raised when an HTTP-layer deadline expires. This is intentionally separate from
lower-level socket timeout exceptions so higher layers can distinguish "request
context expired" from transport-specific readiness or handshake failures.
"""
struct HTTPTimeoutError <: Exception
    operation::String
    timeout_ns::Int64
end

function Base.showerror(io::IO, err::ParseError)
    print(io, "http parse error: ", err.message)
    return nothing
end

function Base.showerror(io::IO, err::ProtocolError)
    print(io, "http protocol error: ", err.message)
    wrapped = err.err
    if wrapped !== nothing
        print(io, " (caused by: ")
        showerror(io, wrapped::Exception)
        print(io, ")")
    end
    return nothing
end

function Base.showerror(io::IO, err::CanceledError)
    print(io, "http canceled: ", err.message)
    return nothing
end

function Base.showerror(io::IO, err::HTTPTimeoutError)
    print(io, "http timeout during ", err.operation, " after ", err.timeout_ns, " ns")
    return nothing
end

"""Shared empty byte-vector payload used for responses with no buffered body."""
const nobody = UInt8[]

@inline function _is_ascii_upper(c::Char)::Bool
    return 'A' <= c <= 'Z'
end

@inline function _is_ascii_lower(c::Char)::Bool
    return 'a' <= c <= 'z'
end

@inline function _to_ascii_upper(c::Char)::Char
    _is_ascii_lower(c) || return c
    return Char(UInt32(c) - 0x20)
end

@inline function _to_ascii_lower(c::Char)::Char
    _is_ascii_upper(c) || return c
    return Char(UInt32(c) + 0x20)
end

@inline function _to_ascii_lower(b::UInt8)::UInt8
    0x41 <= b <= 0x5a || return b
    return b + 0x20
end

@inline function _is_http_ows_byte(b::UInt8)::Bool
    return b == 0x20 || b == 0x09
end

@inline function _is_http_ctl_byte(b::UInt8)::Bool
    return b < 0x20 || b == 0x7f
end

@inline function _is_http_token_byte(b::UInt8)::Bool
    (0x30 <= b <= 0x39 || 0x41 <= b <= 0x5a || 0x61 <= b <= 0x7a) && return true
    return b == 0x21 || b == 0x23 || b == 0x24 || b == 0x25 || b == 0x26 || b == 0x27 ||
           b == 0x2a || b == 0x2b || b == 0x2d || b == 0x2e || b == 0x5e || b == 0x5f ||
           b == 0x60 || b == 0x7c || b == 0x7e
end

function _valid_header_field_name(name::AbstractString)::Bool
    raw = name isa String ? (name::String) : String(name)
    isempty(raw) && return false
    @inbounds for b in codeunits(raw)
        _is_http_token_byte(b) || return false
    end
    return true
end

function _normalize_header_field_value(value::AbstractString)::Union{Nothing,String}
    raw = value isa String ? (value::String) : String(value)
    bytes = codeunits(raw)
    needs_rewrite = false
    @inbounds for b in bytes
        if b == 0x0d || b == 0x0a
            needs_rewrite = true
            continue
        end
        if _is_http_ctl_byte(b) && b != 0x09
            return nothing
        end
    end
    sanitized = if needs_rewrite
        rewritten = Vector{UInt8}(undef, length(bytes))
        @inbounds for i in eachindex(bytes)
            b = bytes[i]
            rewritten[i] = (b == 0x0d || b == 0x0a) ? 0x20 : b
        end
        String(rewritten)
    else
        raw
    end
    return _trim_http_ows(sanitized)
end

const _FORBIDDEN_TRAILER_HEADERS = Set([
    "Authorization",
    "Cache-Control",
    "Connection",
    "Content-Encoding",
    "Content-Length",
    "Content-Range",
    "Content-Type",
    "Expect",
    "Host",
    "Keep-Alive",
    "Max-Forwards",
    "Pragma",
    "Proxy-Authenticate",
    "Proxy-Authorization",
    "Proxy-Connection",
    "Range",
    "Realm",
    "Te",
    "Trailer",
    "Transfer-Encoding",
    "Www-Authenticate",
])

function _valid_trailer_header_name(name::AbstractString)::Bool
    canon = canonical_header_key(name)
    _valid_header_field_name(canon) || return false
    startswith(canon, "If-") && return false
    return !(canon in _FORBIDDEN_TRAILER_HEADERS)
end

function _string_contains_ctl_byte(value::AbstractString)::Bool
    @inbounds for b in codeunits(value)
        _is_http_ctl_byte(b) && return true
    end
    return false
end

@inline function _is_valid_host_header_byte(b::UInt8)::Bool
    (0x30 <= b <= 0x39 || 0x41 <= b <= 0x5a || 0x61 <= b <= 0x7a) && return true
    return b == 0x21 || b == 0x24 || b == 0x25 || b == 0x26 || b == 0x27 || b == 0x28 ||
           b == 0x29 || b == 0x2a || b == 0x2b || b == 0x2c || b == 0x2d || b == 0x2e ||
           b == 0x3a || b == 0x3b || b == 0x3d || b == 0x5b || b == 0x5d || b == 0x5f ||
           b == 0x7e
end

function _valid_host_header(host::AbstractString)::Bool
    @inbounds for b in codeunits(host)
        _is_valid_host_header_byte(b) || return false
    end
    return true
end

const _COMMON_CANONICAL_HEADER_KEYS = Dict(
    "Accept" => "Accept",
    "Accept-Charset" => "Accept-Charset",
    "Accept-Encoding" => "Accept-Encoding",
    "Accept-Language" => "Accept-Language",
    "Accept-Ranges" => "Accept-Ranges",
    "Cache-Control" => "Cache-Control",
    "Connection" => "Connection",
    "Content-Encoding" => "Content-Encoding",
    "Content-Language" => "Content-Language",
    "Content-Length" => "Content-Length",
    "Content-Type" => "Content-Type",
    "Cookie" => "Cookie",
    "Date" => "Date",
    "Host" => "Host",
    "Location" => "Location",
    "Referer" => "Referer",
    "Server" => "Server",
    "Set-Cookie" => "Set-Cookie",
    "Transfer-Encoding" => "Transfer-Encoding",
    "Trailer" => "Trailer",
    "User-Agent" => "User-Agent",
)

"""
    canonical_header_key(key) -> String

Canonicalize a header field name into standard MIME-style form: the first
character and every character after `-` is uppercased; other ASCII letters are
lowercased.

Returns a newly owned `String` unless `key` is already in canonical form, in
which case a cached common-header string may be reused. This function does not
validate that `key` is a legal HTTP token; callers are still responsible for
protocol validation where needed.
"""
function canonical_header_key(key::AbstractString)::String
    isempty(key) && return ""
    key_s = String(key)
    upper_next = true
    canonical = true
    @inbounds for b in codeunits(key_s)
        if upper_next
            if 0x61 <= b <= 0x7a
                canonical = false
                break
            end
        else
            if 0x41 <= b <= 0x5a
                canonical = false
                break
            end
        end
        upper_next = (b == 0x2d)
    end
    if canonical
        return get(() -> key_s, _COMMON_CANONICAL_HEADER_KEYS, key_s)
    end
    chars = Vector{Char}(undef, ncodeunits(key_s))
    upper_next = true
    i = 1
    for c in key_s
        if upper_next
            chars[i] = _to_ascii_upper(c)
        else
            chars[i] = _to_ascii_lower(c)
        end
        upper_next = chars[i] == '-'
        i += 1
    end
    canon = String(chars[1:(i-1)])
    return get(() -> canon, _COMMON_CANONICAL_HEADER_KEYS, canon)
end

"""
    Headers

Ordered, case-canonicalized collection of header pairs.

`Headers` deliberately behaves like `Vector{Pair{String, String}}` so code
written against the long-standing pair-vector header representation can reuse
the same helper functions. Keys are canonicalized on insertion, but pair order
is preserved.
"""
mutable struct Headers <: AbstractVector{Pair{String,String}}
    entries::Vector{Pair{String,String}}
end

"""Create and return an empty `Headers` collection."""
function Headers()
    return Headers(Pair{String,String}[])
end

"""
    Headers(hint)

Create an empty `Headers` collection and use `hint` as a preallocation hint for
the backing pair storage. Throws `ArgumentError` when `hint < 0`.
"""
function Headers(hint::Integer)
    hint < 0 && throw(ArgumentError("hint must be >= 0"))
    entries = Pair{String,String}[]
    sizehint!(entries, Int(hint))
    return Headers(entries)
end

"""
    Headers(headers)

Deep-copy constructor for header collections. The underlying pair storage is
copied, so mutating the result does not affect the source.
"""
function Headers(headers::Headers)
    return Headers(copy(headers.entries))
end

Headers(items::AbstractDict) = mkheaders(items)
Headers(items::AbstractVector) = mkheaders(items)
Headers(items::Tuple) = mkheaders(items)

function Base.copy(headers::Headers)
    return Headers(headers)
end

Base.IndexStyle(::Type{Headers}) = IndexLinear()
Base.eltype(::Type{Headers}) = Pair{String,String}

function Base.size(headers::Headers)
    return (length(headers.entries),)
end

function Base.length(headers::Headers)
    return length(headers.entries)
end

function Base.isempty(headers::Headers)
    return isempty(headers.entries)
end

function Base.empty!(headers::Headers)
    empty!(headers.entries)
    return headers
end

function Base.iterate(headers::Headers, state...)
    return iterate(headers.entries, state...)
end

function Base.getindex(headers::Headers, i::Int)
    return headers.entries[i]
end

@inline function _header_pair(key, value)::Pair{String,String}
    return canonical_header_key(String(key)) => String(value)
end

function Base.setindex!(headers::Headers, item, i::Int)
    headers.entries[i] = _header_pair(first(item), last(item))
    return headers.entries[i]
end

function Base.push!(headers::Headers, item)
    push!(headers.entries, _header_pair(first(item), last(item)))
    return headers
end

"""
    mkheaders(headers_input) -> Headers

Normalize a header-like input into a mutable `Headers` collection.

`headers_input` may be `nothing`, an existing `Headers`, a dictionary, or an
iterable of `Pair`s/2-tuples. Vector-valued entries are expanded into repeated
header values using the same merge rules as `appendheader`.
"""
function mkheaders(headers::Headers)::Headers
    return headers
end

function _append_header_values!(headers::Headers, key, value)
    if value isa AbstractVector && !(value isa AbstractString)
        for item in value
            appendheader(headers, String(key) => String(item))
        end
        return headers
    end
    appendheader(headers, String(key) => String(value))
    return headers
end

function mkheaders(headers_input)
    headers_input === nothing && return Headers()
    headers_input isa Headers && return headers_input
    headers = Headers()
    if headers_input isa AbstractDict
        for (k, v) in pairs(headers_input)
            _append_header_values!(headers, k, v)
        end
        return headers
    end
    for item in headers_input
        if item isa Pair
            pair = item::Pair
            _append_header_values!(headers, pair.first, pair.second)
            continue
        end
        if item isa Tuple && length(item) == 2
            tup = item::Tuple
            _append_header_values!(headers, tup[1], tup[2])
            continue
        end
        throw(ArgumentError("unsupported header entry type $(typeof(item)); expected Pair or 2-tuple"))
    end
    return headers
end

"""Return a newly allocated `Vector{String}` of header keys in insertion order."""
function header_keys(headers::Headers)::Vector{String}
    out = String[]
    seen = Set{String}()
    for (key, _) in headers
        key in seen && continue
        push!(seen, key)
        push!(out, key)
    end
    return out
end

"""Return the first value for `key`, or `default` if the header is absent."""
function header(headers::Headers, key::AbstractString, default="")
    canon = canonical_header_key(key)
    for (name, value) in headers
        name == canon && return value
    end
    return default
end

"""
    headers(headers, key) -> Vector{String}

Return a freshly allocated vector containing all values for `key` in stored
order. Returns `String[]` when the header is absent.
"""
function headers(headers::Headers, key::AbstractString)::Vector{String}
    canon = canonical_header_key(key)
    out = String[]
    for (name, value) in headers
        name == canon && push!(out, value)
    end
    return out
end

"""Return `true` when the first value for `key` is non-empty."""
function hasheader(headers::Headers, key::AbstractString)::Bool
    return header(headers, key) != ""
end

"""
    hasheader(headers, key, value) -> Bool

Return `true` when any stored header value for `key` matches `value`
case-insensitively.
"""
function hasheader(headers::Headers, key::AbstractString, value::AbstractString)::Bool
    canon = canonical_header_key(key)
    for (name, current) in headers
        name == canon || continue
        _ascii_equal_fold(current, value) && return true
    end
    return false
end

"""
    setheader(headers, key => value) -> Headers
    setheader(headers, key, value) -> Headers

Replace all stored values for `key` with `value`, preserving the first matching
position if the key already exists and appending it otherwise. Returns the
mutated `headers`.
"""
function setheader(headers::Headers, header::Pair)
    item = _header_pair(header.first, header.second)
    key = first(item)
    entries = headers.entries
    first_idx = 0
    write_idx = 1
    @inbounds for read_idx in eachindex(entries)
        entry = entries[read_idx]
        if first(entry) == key
            if first_idx == 0
                first_idx = write_idx
                entries[write_idx] = item
                write_idx += 1
            end
            continue
        end
        if write_idx != read_idx
            entries[write_idx] = entry
        end
        write_idx += 1
    end
    if first_idx == 0
        push!(entries, item)
    else
        resize!(entries, write_idx - 1)
    end
    return headers
end

function setheader(headers::Headers, key::AbstractString, value::AbstractString)
    return setheader(headers, key => value)
end

"""
    appendheader(headers, key => value) -> Headers
    appendheader(headers, key, value) -> Headers

Append a header value to `headers`.

If the previous stored header has the same name and the key is not
`Set-Cookie`, the value is merged into the previous entry with a comma.
Otherwise a new pair is appended.
"""
function appendheader(headers::Headers, header::Pair)
    item = _header_pair(header.first, header.second)
    if !isempty(headers.entries)
        last_header = headers.entries[end]
        if first(item) != "Set-Cookie" && first(last_header) == first(item)
            headers.entries[end] = first(last_header) => string(last(last_header), ", ", last(item))
            return headers
        end
    end
    push!(headers.entries, item)
    return headers
end

function appendheader(headers::Headers, key::AbstractString, value::AbstractString)
    return appendheader(headers, key => value)
end

"""
    removeheader(headers, key) -> Headers

Remove every stored header for `key` and return the mutated `headers`.
"""
function removeheader(headers::Headers, key::AbstractString)
    canon = canonical_header_key(key)
    entries = headers.entries
    write_idx = 1
    @inbounds for read_idx in eachindex(entries)
        entry = entries[read_idx]
        if first(entry) == canon
            continue
        end
        if write_idx != read_idx
            entries[write_idx] = entry
        end
        write_idx += 1
    end
    resize!(entries, write_idx - 1)
    return headers
end

@inline function _ascii_lowercase_string(s::AbstractString)::String
    chars = Vector{Char}(undef, ncodeunits(s))
    i = 1
    for c in s
        chars[i] = _to_ascii_lower(c)
        i += 1
    end
    return String(chars[1:(i-1)])
end

@inline function _ascii_equal_fold(a::AbstractString, b::AbstractString)::Bool
    ncodeunits(a) == ncodeunits(b) || return false
    @inbounds for i in 1:ncodeunits(a)
        _to_ascii_lower(codeunit(a, i)) == _to_ascii_lower(codeunit(b, i)) || return false
    end
    return true
end

@inline function _trim_http_ows(s::AbstractString)::String
    lo = firstindex(s)
    hi = lastindex(s)
    while lo <= hi
        c = s[lo]
        if c == ' ' || c == '\t'
            lo = nextind(s, lo)
            continue
        end
        break
    end
    while hi >= lo
        c = s[hi]
        if c == ' ' || c == '\t'
            hi = prevind(s, hi)
            continue
        end
        break
    end
    hi < lo && return ""
    return String(SubString(s, lo, hi))
end

@inline function _trim_http_ows_bounds(bytes)::Tuple{Int,Int}
    lo = firstindex(bytes)
    hi = lastindex(bytes)
    while lo <= hi && _is_http_ows_byte(bytes[lo])
        lo += 1
    end
    while hi >= lo && _is_http_ows_byte(bytes[hi])
        hi -= 1
    end
    return lo, hi
end

@inline function _ascii_equal_fold_slice(
    haystack::Base.CodeUnits{UInt8,String},
    lo::Int,
    hi::Int,
    needle::Base.CodeUnits{UInt8,String},
    needle_lo::Int,
    needle_hi::Int,
)::Bool
    (hi - lo) == (needle_hi - needle_lo) || return false
    j = needle_lo
    @inbounds for i in lo:hi
        _to_ascii_lower(haystack[i]) == _to_ascii_lower(needle[j]) || return false
        j += 1
    end
    return true
end

function _header_value_contains_token(value::String, token::String)::Bool
    token_bytes = codeunits(token)
    token_lo, token_hi = _trim_http_ows_bounds(token_bytes)
    token_hi >= token_lo || return false
    value_bytes = codeunits(value)
    i = firstindex(value_bytes)
    last = lastindex(value_bytes)
    while i <= last
        while i <= last && _is_http_ows_byte(value_bytes[i])
            i += 1
        end
        seg_lo = i
        while i <= last && value_bytes[i] != UInt8(',')
            i += 1
        end
        seg_hi = i - 1
        while seg_hi >= seg_lo && _is_http_ows_byte(value_bytes[seg_hi])
            seg_hi -= 1
        end
        if seg_hi >= seg_lo && _ascii_equal_fold_slice(value_bytes, seg_lo, seg_hi, token_bytes, token_lo, token_hi)
            return true
        end
        i += 1
    end
    return false
end

"""
    headercontains(headers, key, token) -> Bool

Return `true` when a comma-separated header field contains `token`
case-insensitively after trimming optional whitespace.

This is the helper used for semantics like `Connection: close` and
`Transfer-Encoding: chunked`, where RFCs define one header line as a list of
tokens rather than one opaque string.
"""
function headercontains(headers::Headers, key::AbstractString, token::AbstractString)::Bool
    needle = token isa String ? (token::String) : String(token)
    canon = canonical_header_key(key)
    for (name, value) in headers
        name == canon || continue
        _header_value_contains_token(value, needle) && return true
    end
    return false
end

"""
    defaultheader!(headers, key => value) -> Headers
    defaultheader!(message, key => value) -> typeof(message)

Append `key => value` only when `key` is not already present.

This is useful for applying defaults like `User-Agent` or `Accept-Encoding`
without overwriting caller-specified headers.
"""
function defaultheader!(headers::Headers, item::Pair)
    header(headers, first(item), nothing) === nothing || return headers
    return setheader(headers, item)
end

"""
    RequestContext(; deadline_ns=0)

Per-request cancellation and deadline metadata shared across the HTTP client and
server layers.

Arguments:
- `deadline_ns`: absolute monotonic deadline in nanoseconds, or `0` to disable
  deadline tracking.

The context itself does not schedule timers; it is a passive state container
that transport code consults before or during blocking operations.
"""
const _VERBOSE_DEFAULT_BODY_NBYTES = 1000

struct _VerboseConfig
    level::Int
    body_nbytes::Int
    io::IO
end

@inline function _quiet_verbose_config(io::IO=stderr)::_VerboseConfig
    return _VerboseConfig(0, _VERBOSE_DEFAULT_BODY_NBYTES, io)
end

mutable struct _VerboseCaptureBuffer
    bytes::Vector{UInt8}
    limit::Int
    total::Int64
    truncated::Bool
end

function _VerboseCaptureBuffer(limit::Integer)
    limit_i = Int(limit)
    limit_i >= 0 || throw(ArgumentError("capture limit must be >= 0"))
    return _VerboseCaptureBuffer(UInt8[], limit_i, Int64(0), false)
end

mutable struct _ConnReader <: IO
    buf::Vector{UInt8}
    next::Int
    stop::Int
    capture::Union{Nothing,_VerboseCaptureBuffer}
    conn::Union{TCP.Conn,TLS.Conn}
end

mutable struct _VerboseExchangeState
    config::_VerboseConfig
    active::Bool
    protocol::Symbol
    attempt::Int
    redirect_count::Int
    url::String
    request_method::String
    request_target::String
    request_host::Union{Nothing,String}
    request_headers::Headers
    request_proto_major::UInt8
    request_proto_minor::UInt8
    response_status::Int
    response_reason::String
    response_headers::Headers
    response_trailers::Headers
    response_proto_major::UInt8
    response_proto_minor::UInt8
    request_capture::_VerboseCaptureBuffer
    response_capture::_VerboseCaptureBuffer
    @atomic request_logged::Bool
    @atomic response_logged::Bool
    @atomic response_complete::Bool
end

function _VerboseExchangeState(config::_VerboseConfig=_quiet_verbose_config())
    return _VerboseExchangeState(
        config,
        false,
        :auto,
        0,
        0,
        "",
        "",
        "",
        nothing,
        Headers(),
        UInt8(1),
        UInt8(1),
        0,
        "",
        Headers(),
        Headers(),
        UInt8(1),
        UInt8(1),
        _VerboseCaptureBuffer(0),
        _VerboseCaptureBuffer(0),
        false,
        false,
        false,
    )
end

struct _RequestTimeoutConfig
    connect_timeout_ns::Int64
    response_header_timeout_ns::Int64
    read_idle_timeout_ns::Int64
    write_idle_timeout_ns::Int64
    expect_continue_timeout_ns::Int64
end

mutable struct RequestContext
    deadline_ns::Int64
    @atomic canceled_flag::Bool
    cancel_message::Union{Nothing,String}
    metadata::Union{Nothing,Dict{Symbol,Any}}
    timeout_config::Union{Nothing,_RequestTimeoutConfig}
    verbose_config::_VerboseConfig
    verbose_exchange_state::_VerboseExchangeState
end

"""Construct a `RequestContext`; throws `ArgumentError` when `deadline_ns < 0`."""
function RequestContext(; deadline_ns::Integer=Int64(0))
    deadline_ns < 0 && throw(ArgumentError("deadline_ns must be >= 0"))
    verbose_config = _quiet_verbose_config()
    return RequestContext(Int64(deadline_ns), false, nothing, nothing, nothing, verbose_config, _VerboseExchangeState(verbose_config))
end

"""
    set_deadline!(ctx, deadline_ns) -> RequestContext

Set an absolute monotonic deadline in nanoseconds. Passing `0` clears any
deadline. Throws `ArgumentError` when `deadline_ns < 0`.
"""
function set_deadline!(ctx::RequestContext, deadline_ns::Integer)
    deadline_ns < 0 && throw(ArgumentError("deadline_ns must be >= 0"))
    ctx.deadline_ns = Int64(deadline_ns)
    return ctx
end

"""
    cancel!(ctx; message="request canceled") -> RequestContext

Mark `ctx` canceled and store a human-readable message for higher layers. This
does not throw on its own; callers typically check `canceled(ctx)` or turn the
state into a `CanceledError`.
"""
function cancel!(ctx::RequestContext; message::AbstractString="request canceled")
    @atomic :release ctx.canceled_flag = true
    ctx.cancel_message = String(message)
    return ctx
end

"""Return `true` once `cancel!` has been called for `ctx`."""
function canceled(ctx::RequestContext)::Bool
    return @atomic :acquire ctx.canceled_flag
end

"""
    expired(ctx, now_ns=time_ns()) -> Bool

Return `true` when `ctx.deadline_ns` is non-zero and less than or equal to
`now_ns`. `now_ns` is injectable so tests and higher-level schedulers can reuse
an already-sampled monotonic timestamp.
"""
function expired(ctx::RequestContext, now_ns::Integer=time_ns())::Bool
    deadline = ctx.deadline_ns
    deadline <= 0 && return false
    return Int64(now_ns) >= deadline
end

@inline function _request_context_metadata!(
    ctx::RequestContext)::Dict{Symbol,Any}
    metadata = ctx.metadata
    metadata !== nothing && return metadata::Dict{Symbol,Any}
    metadata = Dict{Symbol,Any}()
    ctx.metadata = metadata
    return metadata
end

function Base.haskey(ctx::RequestContext, key::Symbol)::Bool
    metadata = ctx.metadata
    metadata === nothing && return false
    return haskey(metadata::Dict{Symbol,Any}, key)
end

function Base.getindex(ctx::RequestContext, key::Symbol)
    metadata = ctx.metadata
    metadata === nothing && throw(KeyError(key))
    return (metadata::Dict{Symbol,Any})[key]
end

function Base.setindex!(ctx::RequestContext, value, key::Symbol)
    _request_context_metadata!(ctx)[key] = value
    return value
end

function Base.get(default::Function, ctx::RequestContext, key::Symbol)
    metadata = ctx.metadata
    metadata === nothing && return default()
    return get(default, metadata::Dict{Symbol,Any}, key)
end

function Base.get(ctx::RequestContext, key::Symbol, default)
    metadata = ctx.metadata
    metadata === nothing && return default
    return get(metadata::Dict{Symbol,Any}, key, default)
end

function Base.empty!(ctx::RequestContext)
    metadata = ctx.metadata
    metadata === nothing || empty!(metadata::Dict{Symbol,Any})
    ctx.timeout_config = nothing
    return ctx
end

"""
    AbstractBody

Abstract streaming body interface used throughout the HTTP stack.

Concrete subtypes are expected to implement:
- `body_read!(body, dst)::Int`
- `body_close!(body)`
- `body_closed(body)::Bool`

`body_read!` must return the number of bytes written into `dst`, with `0`
signaling EOF. Implementations may throw transport-specific exceptions.
"""
abstract type AbstractBody end

"""Zero-length body that immediately reports EOF and ignores close requests."""
struct EmptyBody <: AbstractBody
end

"""
    BytesBody(data)

Simple in-memory body backed by a retained `AbstractVector{UInt8}`. Reads
advance an internal cursor until EOF; closing marks the body closed but does
not free or truncate the stored bytes.
"""
mutable struct BytesBody{T<:AbstractVector{UInt8}} <: AbstractBody
    data::T
    next_index::Int
    @atomic closed::Bool
end

"""Retain `data` in a new `BytesBody` and reset the read cursor to the start."""
function BytesBody(data::T) where {T<:AbstractVector{UInt8}}
    return BytesBody{T}(data, 1, false)
end

"""
    CallbackBody(read_cb, close_cb)

Callback-driven streaming body. `read_cb(dst)` must return the number of bytes
written into `dst`, and `close_cb()` is invoked once when the body is closed.
This is the escape hatch for non-buffered request or response bodies.
"""
mutable struct CallbackBody{R,C} <: AbstractBody
    read_cb::R
    close_cb::C
    @atomic closed::Bool
end

"""Construct a `CallbackBody` from read and close callbacks."""
function CallbackBody(read_cb::R, close_cb::C) where {R,C}
    return CallbackBody{R,C}(read_cb, close_cb, false)
end

"""
    body_closed(body) -> Bool

Return `true` once `body` has been fully consumed or explicitly closed.

For immutable in-memory bodies this tracks whether the read cursor reached EOF;
for streaming bodies it reports whether the underlying producer has been closed.
"""
function body_closed(::EmptyBody)::Bool
    return false
end

function body_closed(body::BytesBody)::Bool
    return @atomic :acquire body.closed
end

function body_closed(body::CallbackBody)::Bool
    return @atomic :acquire body.closed
end

"""
    body_read!(body, dst) -> Int

Read up to `length(dst)` bytes into `dst`. Returns `0` on EOF.

Concrete body types may throw `ProtocolError`, transport errors, or body-
specific exceptions if the stream is malformed or the backing connection fails.
"""
function body_read!(::EmptyBody, dst::Vector{UInt8})::Int
    _ = dst
    return 0
end

function body_read!(body::BytesBody, dst::Vector{UInt8})::Int
    body_closed(body) && return 0
    isempty(dst) && return 0
    available = (length(body.data) - body.next_index) + 1
    available <= 0 && return 0
    n = min(length(dst), available)
    copyto!(dst, 1, body.data, body.next_index, n)
    body.next_index += n
    return n
end

function body_read!(body::CallbackBody, dst::Vector{UInt8})::Int
    body_closed(body) && return 0
    n = Int(body.read_cb(dst))
    n < 0 && throw(ProtocolError("body read callback returned negative byte count"))
    n <= length(dst) || throw(ProtocolError("body read callback exceeded destination buffer length"))
    return n
end

"""
    body_close!(body)

Release any resources held by `body`. Implementations should be idempotent so
callers can safely close in `finally` blocks.
"""
function body_close!(::EmptyBody)
    return nothing
end

function body_close!(body::BytesBody)
    @atomic :release body.closed = true
    return nothing
end

function body_close!(body::CallbackBody)
    was_closed = body_closed(body)
    was_closed && return nothing
    @atomic :release body.closed = true
    body.close_cb()
    return nothing
end

@inline _body_immediately_empty(::AbstractBody)::Bool = false
@inline _body_immediately_empty(::EmptyBody)::Bool = true
@inline _body_uses_eof_framing(::AbstractBody)::Bool = false

"""
    Request(method, target; headers=Headers(), trailers=Headers(), body=EmptyBody(), host=nothing,
            content_length=-1, proto_major=1, proto_minor=1, close=false,
            context=RequestContext())

HTTP request object shared by the client and server stacks.

Keyword arguments:
- `headers`, `trailers`: copied into the request.
- `body`: any `AbstractBody`; ownership stays with the request.
- `host`: optional authority used for HTTP/1 `Host` and HTTP/2 `:authority`.
- `content_length`: exact byte length, or `-1` when unknown.
- `proto_major`, `proto_minor`: protocol version metadata.
- `close`: request/connection-close hint.
- `context`: cancellation/deadline metadata consulted by higher layers.

Returns a new `Request{B}` where `B` is the concrete body type. Throws
`ArgumentError` for invalid protocol numbers, empty method/target, or
`content_length < -1`.
"""
mutable struct Request{B<:AbstractBody}
    method::String
    target::String
    headers::Headers
    trailers::Headers
    body::B
    host::Union{Nothing,String}
    content_length::Int64
    proto_major::UInt8
    proto_minor::UInt8
    close::Bool
    context::RequestContext
end

function Request(
    method::AbstractString,
    target::AbstractString;
    headers=Headers(),
    trailers=Headers(),
    body::B=EmptyBody(),
    host::Union{Nothing,AbstractString}=nothing,
    content_length::Integer=Int64(-1),
    proto_major::Integer=1,
    proto_minor::Integer=1,
    close::Bool=false,
    context::RequestContext=RequestContext(),
) where {B<:AbstractBody}
    isempty(method) && throw(ArgumentError("method must not be empty"))
    isempty(target) && throw(ArgumentError("target must not be empty"))
    content_length < -1 && throw(ArgumentError("content_length must be >= -1"))
    (proto_major < 0 || proto_major > typemax(UInt8)) && throw(ArgumentError("proto_major must fit in UInt8"))
    (proto_minor < 0 || proto_minor > typemax(UInt8)) && throw(ArgumentError("proto_minor must fit in UInt8"))
    host_s = host === nothing ? nothing : String(host)
    return Request{B}(
        String(method),
        String(target),
        copy(mkheaders(headers)),
        copy(mkheaders(trailers)),
        body,
        host_s,
        Int64(content_length),
        UInt8(proto_major),
        UInt8(proto_minor),
        close,
        context,
    )
end

@inline function _request_nocopy(
    method::String,
    target::String,
    headers::Headers,
    trailers::Headers,
    body::B,
    host::Union{Nothing,String},
    content_length::Int64,
    proto_major::UInt8,
    proto_minor::UInt8,
    close::Bool,
    context::RequestContext,
)::Request{B} where {B<:AbstractBody}
    return Request{B}(
        method,
        target,
        headers,
        trailers,
        body,
        host,
        content_length,
        proto_major,
        proto_minor,
        close,
        context,
    )
end

@inline function _request_with_context(
    request::Request{B},
    context::RequestContext,
)::Request{B} where {B<:AbstractBody}
    return _request_nocopy(
        request.method,
        request.target,
        request.headers,
        request.trailers,
        request.body,
        request.host,
        request.content_length,
        request.proto_major,
        request.proto_minor,
        request.close,
        context,
    )
end

"""
    Response(status, body=EmptyBody(); reason="", headers=Headers(), trailers=Headers(),
             content_length=-1, proto_major=1, proto_minor=1, close=false,
             request=nothing)

HTTP response object shared by the client and server stacks.

Keyword arguments mirror `Request` closely. `request` optionally links the
response back to the originating request, which is especially useful in client
redirect flows and server handler pipelines.

    Returns a new `Response{B}` where `B` is the exact body field type. The
    optional `body` positional argument determines the response body type for
    dispatch and storage. `request_url` is optional client metadata used by
    high-level request helpers.

    Throws `ArgumentError` for invalid status or protocol metadata.
"""
mutable struct Response{B}
    status::Int
    reason::String
    headers::Headers
    trailers::Headers
    body::B
    content_length::Int64
    proto_major::UInt8
    proto_minor::UInt8
    close::Bool
    request::Union{Nothing,Request}
    request_url::Union{Nothing,String}
    previous::Union{Nothing,Response}
    redirect_count::Int
end

struct _IncomingResponseHead
    status::Int
    reason::String
    headers::Headers
    trailers::Headers
    content_length::Int64
    proto_major::UInt8
    proto_minor::UInt8
    close::Bool
    request::Union{Nothing,Request}
    request_url::Union{Nothing,String}
    previous::Union{Nothing,Response}
    redirect_count::Int
end

struct _IncomingResponse{B<:AbstractBody}
    head::_IncomingResponseHead
    rawbody::B
end

function Response(
    status::Integer,
    body::B=EmptyBody();
    reason::AbstractString="",
    headers=Headers(),
    trailers=Headers(),
    content_length::Integer=Int64(-1),
    proto_major::Integer=1,
    proto_minor::Integer=1,
    close::Bool=false,
    request::Union{Nothing,Request}=nothing,
    request_url::Union{Nothing,AbstractString}=nothing,
    previous::Union{Nothing,Response}=nothing,
    redirect_count::Integer=0,
) where {B}
    status < 0 && throw(ArgumentError("status must be >= 0"))
    content_length < -1 && throw(ArgumentError("content_length must be >= -1"))
    redirect_count < 0 && throw(ArgumentError("redirect_count must be >= 0"))
    (proto_major < 0 || proto_major > typemax(UInt8)) && throw(ArgumentError("proto_major must fit in UInt8"))
    (proto_minor < 0 || proto_minor > typemax(UInt8)) && throw(ArgumentError("proto_minor must fit in UInt8"))
    return Response{B}(
        Int(status),
        String(reason),
        copy(mkheaders(headers)),
        copy(mkheaders(trailers)),
        body,
        Int64(content_length),
        UInt8(proto_major),
        UInt8(proto_minor),
        close,
        request,
        request_url === nothing ? nothing : String(request_url),
        previous,
        Int(redirect_count),
    )
end

@inline function _response_nocopy_exact(
    status::Int,
    reason::String,
    headers::Headers,
    trailers::Headers,
    body::B,
    content_length::Int64,
    proto_major::UInt8,
    proto_minor::UInt8,
    close::Bool,
    request::Union{Nothing,Request},
    request_url::Union{Nothing,String},
    previous::Union{Nothing,Response},
    redirect_count::Int,
)::Response{B} where {B}
    return Response{B}(
        status,
        reason,
        headers,
        trailers,
        body,
        content_length,
        proto_major,
        proto_minor,
        close,
        request,
        request_url,
        previous,
        redirect_count,
    )
end

header(message::Union{Request,Response}, key::AbstractString, default="") =
    header(message.headers, key, default)

headers(message::Union{Request,Response}, key::AbstractString)::Vector{String} =
    headers(message.headers, key)

hasheader(message::Union{Request,Response}, key::AbstractString)::Bool =
    hasheader(message.headers, key)

hasheader(message::Union{Request,Response}, key::AbstractString, value::AbstractString)::Bool =
    hasheader(message.headers, key, value)

headercontains(message::Union{Request,Response}, key::AbstractString, value::AbstractString)::Bool =
    headercontains(message.headers, key, value)

function setheader(message::Union{Request,Response}, header::Pair)
    setheader(message.headers, header)
    return message
end

function setheader(message::Union{Request,Response}, key::AbstractString, value::AbstractString)
    setheader(message.headers, key, value)
    return message
end

function defaultheader!(message::Union{Request,Response}, header::Pair)
    defaultheader!(message.headers, header)
    return message
end

function appendheader(message::Union{Request,Response}, header::Pair)
    appendheader(message.headers, header)
    return message
end

function appendheader(message::Union{Request,Response}, key::AbstractString, value::AbstractString)
    appendheader(message.headers, key, value)
    return message
end

function removeheader(message::Union{Request,Response}, key::AbstractString)
    removeheader(message.headers, key)
    return message
end

Base.getindex(message::Union{Request,Response}, key::AbstractString) = header(message, key)

function Base.getproperty(response::Response, field::Symbol)
    field === :url && return getfield(response, :request_url)
    return getfield(response, field)
end

function _streaming_response(incoming::_IncomingResponse)
    head = incoming.head
    return _response_nocopy_exact(
        head.status,
        head.reason,
        head.headers,
        head.trailers,
        incoming.rawbody,
        head.content_length,
        head.proto_major,
        head.proto_minor,
        head.close,
        head.request,
        head.request_url,
        head.previous,
        head.redirect_count,
    )
end
