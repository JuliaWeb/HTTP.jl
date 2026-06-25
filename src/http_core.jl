# Core HTTP request/response/header/body types and errors.
using Reseau.TCP
using Reseau.TLS
using Reseau.IOPoll
using Reseau.HostResolvers

"""
    HTTPError

Abstract supertype for HTTP-specific exceptions raised by HTTP.jl.
"""
abstract type HTTPError <: Exception end

"""
    ParseError

Raised when byte-level HTTP syntax cannot be parsed. This is used for malformed
request/status lines, invalid header syntax, truncated framed bodies, and other
wire-format failures where the peer did not send valid HTTP.
"""
struct ParseError <: HTTPError
    message::String
end

@enum _ProtocolErrorCode::UInt8 begin
    _PROTOCOL_ERROR_GENERIC = 0
    _PROTOCOL_ERROR_LINE_TOO_LONG = 1
    _PROTOCOL_ERROR_HEADERS_TOO_LARGE = 2
    _PROTOCOL_ERROR_BODY_TOO_LARGE = 3
end

"""
    ProtocolError

Raised when the bytes are syntactically valid but violate higher-level HTTP
rules. Examples include mismatched `Content-Length` values, impossible frame
ordering, or unsupported control-flow states in the client/server stacks.
"""
struct ProtocolError <: HTTPError
    message::String
    code::_ProtocolErrorCode
    err::Union{Nothing,Exception}
end

ProtocolError(msg, err::Exception) = ProtocolError(String(msg), _PROTOCOL_ERROR_GENERIC, err)
ProtocolError(msg, code::_ProtocolErrorCode=_PROTOCOL_ERROR_GENERIC) = ProtocolError(String(msg), code, nothing)

const _DEFAULT_SSE_CLIENT_MAX_LINE_BYTES = 1 * 1024 * 1024
const _DEFAULT_SSE_CLIENT_MAX_EVENT_BYTES = 16 * 1024 * 1024

"""
    CanceledError

Raised when request processing is canceled explicitly through `RequestContext`.
Unlike `ParseError` and `ProtocolError`, this usually reflects local control
flow rather than a bad peer.
"""
struct CanceledError <: HTTPError
    message::String
end

"""
    TimeoutError

Raised when an HTTP-layer deadline expires. This is intentionally separate from
lower-level socket timeout exceptions so higher layers can distinguish "request
context expired" from transport-specific readiness or handshake failures.

Fields:

- `operation::String` — short label identifying which deadline fired. Common
  values are `"connect"`, `"tls_handshake"`, `"request"`, `"response_header"`,
  `"read_idle"`, `"write_idle"`, and `"expect_continue"`.
- `timeout_ns::Int64` — the budget that fired, in nanoseconds. `0` means the
  budget was unknown at the wrap site.
- `elapsed_ns::Int64` — best-effort elapsed time when the deadline fired, in
  nanoseconds. `0` means the elapsed time is unknown at the wrap site.
"""
struct TimeoutError <: HTTPError
    operation::String
    timeout_ns::Int64
    elapsed_ns::Int64
end

TimeoutError(operation::AbstractString, timeout_ns::Integer) =
    TimeoutError(String(operation), Int64(timeout_ns), Int64(0))

"""
    ConnectError(address, cause)

Raised when a low-level connect attempt fails before any HTTP exchange begins.
`address` records the target the client tried to reach (host:port) and `cause`
is the underlying transport exception. This wraps Reseau-internal types like
`HostResolvers.OpError` so callers can pattern-match on `HTTP.ConnectError`
without depending on Reseau internals.
"""
struct ConnectError <: HTTPError
    address::String
    cause::Exception
end

ConnectError(address::AbstractString, cause::Exception) = ConnectError(String(address), cause)

"""
    DNSError(hostname, cause)

Raised when host resolution fails before any connect attempt. `hostname` is the
name that could not be resolved and `cause` is the underlying transport
exception (typically `Reseau.HostResolvers.LookupError`).
"""
struct DNSError <: HTTPError
    hostname::String
    cause::Exception
end

DNSError(hostname::AbstractString, cause::Exception) = DNSError(String(hostname), cause)

"""
    TLSHandshakeError(cause)

Raised when a TLS handshake fails (other than a handshake timeout, which
surfaces as [`TimeoutError`](@ref) with `operation = "tls_handshake"`).
"""
struct TLSHandshakeError <: HTTPError
    cause::Exception
end

"""
    AddressInUseError(address)

Raised when a server cannot bind because the requested address is already in
use. `address` records the bind target (host:port).
"""
struct AddressInUseError <: HTTPError
    address::String
end

AddressInUseError(address::AbstractString) = AddressInUseError(String(address))

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

function Base.showerror(io::IO, err::TimeoutError)
    print(io, "http timeout during ", err.operation)
    if err.timeout_ns > 0
        print(io, " (budget ", err.timeout_ns, " ns")
        if err.elapsed_ns > 0
            print(io, ", elapsed ", err.elapsed_ns, " ns")
        end
        print(io, ")")
    elseif err.elapsed_ns > 0
        print(io, " (elapsed ", err.elapsed_ns, " ns)")
    end
    return nothing
end

function Base.showerror(io::IO, err::ConnectError)
    print(io, "http connect error to ", err.address, ": ")
    showerror(io, err.cause)
    return nothing
end

function Base.showerror(io::IO, err::DNSError)
    print(io, "http dns error for ", err.hostname, ": ")
    showerror(io, err.cause)
    return nothing
end

function Base.showerror(io::IO, err::TLSHandshakeError)
    print(io, "http tls handshake error: ")
    showerror(io, err.cause)
    return nothing
end

function Base.showerror(io::IO, err::AddressInUseError)
    print(io, "http address already in use: ", err.address)
    return nothing
end

"""
    HTTPTimeoutError

Public alias for [`TimeoutError`](@ref), kept so code can catch timeout
failures through the long-form HTTP-specific name.
"""
const HTTPTimeoutError = TimeoutError

"""
    _is_transport_timeout(err)

Return `true` if `err` is one of the lower-level transport/resolver/TLS timeout
exceptions raised by Reseau. These are intentionally wrapped at the public HTTP
boundary so callers can pattern-match against [`TimeoutError`](@ref) /
[`HTTPTimeoutError`](@ref) without depending on Reseau internals.
"""
@inline function _is_transport_timeout(err)::Bool
    err isa IOPoll.DeadlineExceededError && return true
    err isa HostResolvers.DialTimeoutError && return true
    err isa TLS.TLSHandshakeTimeoutError && return true
    return false
end

"""
    _is_address_in_use_systemerror(err)

Heuristic that returns `true` when `err::SystemError` corresponds to the
"address already in use" condition (`EADDRINUSE`).
"""
@inline function _is_address_in_use_systemerror(err::Base.SystemError)::Bool
    return Int(err.errnum) == Int(Base.Libc.EADDRINUSE)
end

"""
    _wrap_transport_timeout(err, operation, timeout_ns=0, elapsed_ns=0)

If `err` is a transport-level timeout exception (see [`_is_transport_timeout`](@ref)),
return an [`HTTPTimeoutError`](@ref) tagged with `operation`. Otherwise return
`err` unchanged. Used at public HTTP boundaries to keep timeout exceptions
catchable as `HTTP.TimeoutError`.
"""
@inline function _wrap_transport_timeout(err, operation::AbstractString, timeout_ns::Integer=Int64(0), elapsed_ns::Integer=Int64(0))
    _is_transport_timeout(err) || return err
    return TimeoutError(String(operation), Int64(timeout_ns), Int64(elapsed_ns))
end

@inline function _opaddress(err::HostResolvers.OpError)::String
    addr = err.addr
    addr === nothing && return ""
    return string(addr)
end

function _wrap_op_error(err::HostResolvers.OpError, operation::AbstractString, timeout_ns::Int64, elapsed_ns::Int64=Int64(0))
    inner = err.err
    address = _opaddress(err)
    if inner isa HostResolvers.DialTimeoutError
        return TimeoutError(String("connect"), timeout_ns, elapsed_ns)
    end
    if inner isa TLS.TLSHandshakeTimeoutError
        return TimeoutError(String("tls_handshake"), Int64(inner.timeout_ns), elapsed_ns)
    end
    if inner isa IOPoll.DeadlineExceededError
        return TimeoutError(String(operation), timeout_ns, elapsed_ns)
    end
    if inner isa HostResolvers.LookupError
        return DNSError(inner.name, err)
    end
    if inner isa TLS.TLSError
        return TLSHandshakeError(err)
    end
    if inner isa Base.SystemError && _is_address_in_use_systemerror(inner)
        return AddressInUseError(address)
    end
    return ConnectError(address, err)
end

"""
    _wrap_client_transport_error(err, operation="request", timeout_ns=0, elapsed_ns=0)

Wrap Reseau-internal transport errors that escape the client request path so
callers see HTTP-typed exceptions only. Returns either a wrapped
[`TimeoutError`](@ref), [`ConnectError`](@ref), [`DNSError`](@ref),
[`TLSHandshakeError`](@ref), or `err` unchanged when no wrapping rule applies.
"""
function _wrap_client_transport_error(err, operation::AbstractString="request", timeout_ns::Integer=Int64(0), elapsed_ns::Integer=Int64(0))
    if err isa TLS.TLSHandshakeTimeoutError
        return TimeoutError(String("tls_handshake"), Int64(err.timeout_ns), Int64(elapsed_ns))
    end
    if err isa HostResolvers.DialTimeoutError
        return TimeoutError(String("connect"), Int64(timeout_ns), Int64(elapsed_ns))
    end
    if err isa IOPoll.DeadlineExceededError
        return TimeoutError(String(operation), Int64(timeout_ns), Int64(elapsed_ns))
    end
    if err isa HostResolvers.OpError
        return _wrap_op_error(err::HostResolvers.OpError, operation, Int64(timeout_ns), Int64(elapsed_ns))
    end
    if err isa HostResolvers.LookupError
        return DNSError(err.name, err)
    end
    if err isa TLS.TLSError
        return TLSHandshakeError(err)
    end
    return err
end

"""
    _wrap_server_listen_error(err, address)

Wrap Reseau-internal listen errors so server callers (e.g. `serve!`/`listen!`)
see HTTP-typed exceptions only. Returns [`AddressInUseError`](@ref) when the
underlying error is `EADDRINUSE`, otherwise rewraps as [`ConnectError`](@ref)
to keep the bind failure under the HTTPError hierarchy.
"""
function _wrap_server_listen_error(err, address::AbstractString)
    if err isa HostResolvers.OpError
        inner = err.err
        if inner isa Base.SystemError && _is_address_in_use_systemerror(inner)
            return AddressInUseError(address)
        end
        return ConnectError(String(address), err)
    end
    if err isa Base.SystemError && _is_address_in_use_systemerror(err)
        return AddressInUseError(address)
    end
    return err
end

"""Shared empty byte-vector payload used for responses with no buffered body."""
const nobody = UInt8[]
const _BASE64_ALPHABET = codeunits("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

macro try_ignore(ex)
    return quote
        try
            $(esc(ex))
        catch
            nothing
        end
        nothing
    end
end

function _base64encode(data::AbstractVector{UInt8})::String
    n = length(data)
    n == 0 && return ""
    out = Vector{UInt8}(undef, 4 * cld(n, 3))
    alphabet = _BASE64_ALPHABET
    i = 1
    j = 1
    @inbounds while i + 2 <= n
        b1 = data[i]
        b2 = data[i + 1]
        b3 = data[i + 2]
        out[j] = alphabet[Int(b1 >>> 2) + 1]
        out[j + 1] = alphabet[Int(((b1 & 0x03) << 4) | (b2 >>> 4)) + 1]
        out[j + 2] = alphabet[Int(((b2 & 0x0f) << 2) | (b3 >>> 6)) + 1]
        out[j + 3] = alphabet[Int(b3 & 0x3f) + 1]
        i += 3
        j += 4
    end
    remaining = n - i + 1
    if remaining == 1
        b1 = @inbounds data[i]
        out[j] = alphabet[Int(b1 >>> 2) + 1]
        out[j + 1] = alphabet[Int((b1 & 0x03) << 4) + 1]
        out[j + 2] = 0x3d
        out[j + 3] = 0x3d
    elseif remaining == 2
        b1 = @inbounds data[i]
        b2 = @inbounds data[i + 1]
        out[j] = alphabet[Int(b1 >>> 2) + 1]
        out[j + 1] = alphabet[Int(((b1 & 0x03) << 4) | (b2 >>> 4)) + 1]
        out[j + 2] = alphabet[Int((b2 & 0x0f) << 2) + 1]
        out[j + 3] = 0x3d
    end
    return String(out)
end

@inline function _base64encode(data::AbstractString)::String
    return _base64encode(codeunits(data))
end

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

function _valid_header_field_name(name::AbstractString)::Bool
    raw = name isa String ? (name::String) : String(name)
    isempty(raw) && return false
    @inbounds for b in codeunits(raw)
        (0x30 <= b <= 0x39 || 0x41 <= b <= 0x5a || 0x61 <= b <= 0x7a ||
         b == 0x21 || b == 0x23 || b == 0x24 || b == 0x25 || b == 0x26 || b == 0x27 ||
         b == 0x2a || b == 0x2b || b == 0x2d || b == 0x2e || b == 0x5e || b == 0x5f ||
         b == 0x60 || b == 0x7c || b == 0x7e) || return false
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
        if (b < 0x20 || b == 0x7f) && b != 0x09
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

function _normalize_strict_header_field_value(value::AbstractString)::Union{Nothing,String}
    raw = value isa String ? (value::String) : String(value)
    @inbounds for b in codeunits(raw)
        if b == 0x0d || b == 0x0a
            return nothing
        end
    end
    return _normalize_header_field_value(raw)
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
        (b < 0x20 || b == 0x7f) && return true
    end
    return false
end

# True if `value` contains an ASCII SP (0x20) or HTAB (0x09). Used to reject
# interior whitespace in fields (e.g. the HTTP/2 :path pseudo-header) that must
# not be split when re-serialized into an HTTP/1 request line (RFC 9113 8.3.1).
function _string_contains_whitespace_byte(value::AbstractString)::Bool
    @inbounds for b in codeunits(value)
        (b == 0x20 || b == 0x09) && return true
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
    "Accept-Query" => "Accept-Query",
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
Headers() = Headers(Pair{String,String}[])

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
Headers(headers::Headers) = Headers(copy(headers.entries))

Headers(items::AbstractDict) = mkheaders(items)
Headers(items::AbstractVector) = mkheaders(items)
Headers(items::Tuple) = mkheaders(items)

"""
    Headers(items...; kwargs...) -> Headers

Construct a canonicalized Headers from items and/or kwargs
"""
Headers(items::Union{Pair,Tuple}...; kwargs...) = mkheaders(items...; kwargs...)

Base.copy(headers::Headers) = Headers(headers)

Base.IndexStyle(::Type{Headers}) = IndexLinear()
Base.eltype(::Type{Headers}) = Pair{String,String}

Base.size(headers::Headers) = (length(headers.entries),)

Base.length(headers::Headers) = length(headers.entries)

Base.isempty(headers::Headers) = isempty(headers.entries)

function Base.empty!(headers::Headers)
    empty!(headers.entries)
    return headers
end

Base.iterate(headers::Headers, state...) = iterate(headers.entries, state...)

Base.getindex(headers::Headers, i::Int) = headers.entries[i]

@inline function _header_pair(key, value)::Pair{String,String}
    return canonical_header_key(String(key)) => String(value)
end

function Base.setindex!(headers::Headers, item, i::Int)
    headers.entries[i] = _header_pair(first(item), last(item))
    return headers.entries[i]
end

function Base.setindex!(headers::Headers, value, key::Union{Symbol, AbstractString})
    setheader(headers, String(key) => string(value))
end

function Base.merge!(headers::Headers, items)
    for (key, value) in Headers(items)
        if key == "Set-Cookie"
            push!(headers.entries, key => value)
        else
            setheader(headers, key => value)
        end
    end
    return headers
end

function Base.append!(headers::Headers, items)
    for (key, value) in Headers(items)
        appendheader(headers, key => value)
    end
    return headers
end

function Base.push!(headers::Headers, item)
    push!(headers.entries, _header_pair(first(item), last(item)))
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

"""
    mkheaders(headers_input) -> Headers

Normalize a header-like input into a mutable `Headers` collection.

`headers_input` may be `nothing`, a pair or 2-tuple, an existing `Headers`, a dictionary, or an
iterable of `Pair`s/2-tuples. Vector-valued entries are expanded into repeated
header values using the same merge rules as `appendheader`.
"""
function mkheaders(headers_input)
    headers_input === nothing && return Headers()
    headers_input isa Headers && return headers_input
    headers = Headers()
    if headers_input isa AbstractDict
        for (k, v) in pairs(headers_input)
            _append_header_values!(headers, k, v)
        end
        return headers
    elseif headers_input isa Pair
        pair = headers_input::Pair
        _append_header_values!(headers, pair.first, pair.second)
        return headers
    elseif headers_input isa Tuple && length(headers_input) == 2
        tup = headers_input::Tuple
        _append_header_values!(headers, tup[1], tup[2])
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

mkheaders(items::Union{Pair,Tuple}...; kwargs...) = mkheaders(Base.Iterators.flatten((items, kwargs)))

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
    headers[key] -> String

Dict-style indexing on `Headers`. Returns the canonical first value for
`key`, throwing `KeyError(key)` if the header is absent or has empty value.
Use [`HTTP.header`](@ref) when you want a string default instead of an
exception.
"""
function Base.getindex(headers::Headers, key::AbstractString)::String
    v = header(headers, key)
    isempty(v) || return v
    hasheader(headers, key) || throw(KeyError(key))
    return v
end

"""
    get(headers, key, default) -> String

Dict-style `get` on `Headers`. Returns the first value for `key`, or
`default` if the header is absent.
"""
function Base.get(headers::Headers, key::AbstractString, default)
    v = header(headers, key)
    !isempty(v) && return v
    hasheader(headers, key) && return v
    return default
end

"""
    haskey(headers, key) -> Bool

Dict-style `haskey` on `Headers`. Returns `true` when `key` is present
(case-insensitive), regardless of whether its value is empty.
"""
function Base.haskey(headers::Headers, key::AbstractString)::Bool
    canon = canonical_header_key(key)
    for (name, _) in headers
        name == canon && return true
    end
    return false
end

# Request/Response convenience overloads are added later in this file once
# those types are defined.

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
    while lo <= hi && (bytes[lo] == 0x20 || bytes[lo] == 0x09)
        lo += 1
    end
    while hi >= lo && (bytes[hi] == 0x20 || bytes[hi] == 0x09)
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
        while i <= last && (value_bytes[i] == 0x20 || value_bytes[i] == 0x09)
            i += 1
        end
        seg_lo = i
        while i <= last && value_bytes[i] != UInt8(',')
            i += 1
        end
        seg_hi = i - 1
        while seg_hi >= seg_lo && (value_bytes[seg_hi] == 0x20 || value_bytes[seg_hi] == 0x09)
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
Read at least one byte into `b` (up to `nb`), blocking until data is available
or EOF, and return the number of bytes read (`0` only at EOF).

The WebSocket read loop relies on Reseau's "block until at least one byte or
EOF" semantics, which `readbytes!(conn; all=false)` provides for Reseau conns.
A stdlib `TCPSocket` with `all=false` instead returns `0` whenever no bytes are
buffered *yet*, so for any other `IO` we reimplement the blocking contract on
top of `eof`/`bytesavailable`. This lets `WebSockets.open(io)` accept an
arbitrary caller-provided stream that bypasses the connection pool.
"""
function _blocking_readbytes!(conn::Union{TCP.Conn,TLS.Conn}, b::AbstractVector{UInt8}, nb::Integer=length(b))
    readbytes!(conn, b, nb; all=false)
end

function _blocking_readbytes!(io::IO, b::AbstractVector{UInt8}, nb::Integer=length(b))
    eof(io) && return 0
    n = min(bytesavailable(io), Int(nb))
    return readbytes!(io, b, n)
end

"""
Internal buffered reader that first drains already-read bytes before continuing
from the underlying TCP or TLS connection.
"""
mutable struct _ConnReader <: IO
    buf::Vector{UInt8}
    next::Int
    stop::Int
    conn::Union{TCP.Conn,TLS.Conn}
end

"""
Per-request timeout bundle normalized to nanoseconds and attached to
`RequestContext` for transport and stream code.
"""
struct _RequestTimeoutConfig
    connect_timeout_ns::Int64
    response_header_timeout_ns::Int64
    read_idle_timeout_ns::Int64
    write_idle_timeout_ns::Int64
    expect_continue_timeout_ns::Int64
end

"""
    RequestContext(; deadline_ns=0)

Per-request cancellation, deadline, timeout, and metadata state shared across
client, server, middleware, and transport code.

Arguments:
- `deadline_ns`: absolute monotonic deadline in nanoseconds, or `0` to disable
  deadline tracking.

The context itself does not schedule timers; it is a passive state container
that HTTP.jl consults before or during blocking operations. For migration from
HTTP.jl 1.x, `RequestContext` also supports dict-like metadata access with
symbol keys:

```julia
ctx = HTTP.RequestContext()
ctx[:request_id] = "abc"
get(ctx, :request_id, nothing)
```

New code should prefer typed fields and helper functions for cancellation and
deadlines, and reserve dict-like access for application metadata.
"""
mutable struct RequestContext
    deadline_ns::Int64
    @atomic canceled_flag::Bool
    cancel_message::Union{Nothing,String}
    metadata::Union{Nothing,Dict{Symbol,Any}}
    timeout_config::Union{Nothing,_RequestTimeoutConfig}
    cancel_callbacks_lock::ReentrantLock
    cancel_callbacks::Vector{Function}
end

"""Construct a `RequestContext`; throws `ArgumentError` when `deadline_ns < 0`."""
function RequestContext(; deadline_ns::Integer=Int64(0))
    deadline_ns < 0 && throw(ArgumentError("deadline_ns must be >= 0"))
    return RequestContext(Int64(deadline_ns), false, nothing, nothing, nothing, ReentrantLock(), Function[])
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
    lock(ctx.cancel_callbacks_lock)
    callbacks = try
        copy(ctx.cancel_callbacks)
    finally
        unlock(ctx.cancel_callbacks_lock)
    end
    for cb in callbacks
        try
            cb()
        catch
            # callbacks must not propagate errors back into cancel!
        end
    end
    return ctx
end

@inline function _cancel_message(ctx::RequestContext)::String
    msg = ctx.cancel_message
    return msg === nothing ? "request canceled" : msg::String
end

@inline function _canceled_error(ctx::RequestContext)::CanceledError
    return CanceledError(_cancel_message(ctx))
end

"""
    _on_cancel!(ctx, callback) -> ctx

Register `callback` (a zero-argument function) to run when `cancel!(ctx)` fires.
If `ctx` is already canceled, `callback` runs immediately. Internal helper used
by the transport layer to interrupt in-flight reads/writes.
"""
function _on_cancel!(ctx::RequestContext, callback::Function)
    if (@atomic :acquire ctx.canceled_flag)
        try
            callback()
        catch
        end
        return ctx
    end
    lock(ctx.cancel_callbacks_lock)
    try
        if (@atomic :acquire ctx.canceled_flag)
            try
                callback()
            catch
            end
        else
            push!(ctx.cancel_callbacks, callback)
        end
    finally
        unlock(ctx.cancel_callbacks_lock)
    end
    return ctx
end

"""
    _remove_cancel_callback!(ctx, callback) -> ctx

Remove a previously-registered cancellation callback if still present.
"""
function _remove_cancel_callback!(ctx::RequestContext, callback::Function)
    lock(ctx.cancel_callbacks_lock)
    try
        for (idx, cb) in enumerate(ctx.cancel_callbacks)
            if cb === callback
                deleteat!(ctx.cancel_callbacks, idx)
                break
            end
        end
    finally
        unlock(ctx.cancel_callbacks_lock)
    end
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

@inline function _compat_request_context(context)::RequestContext
    context isa RequestContext && return context::RequestContext
    context === nothing && return RequestContext()
    context isa AbstractDict || throw(ArgumentError("context must be a RequestContext, Dict-like object, or nothing"))
    ctx = RequestContext()
    metadata = _request_context_metadata!(ctx)
    for (key, value) in pairs(context::AbstractDict)
        key isa Symbol || throw(ArgumentError("request context keys must be Symbol"))
        metadata[key::Symbol] = value
    end
    return ctx
end

@inline function _compat_proto_version(version, default_major::Int=1, default_minor::Int=1)::Tuple{Int,Int}
    version === nothing && return default_major, default_minor
    if version isa VersionNumber
        return Int((version::VersionNumber).major), Int((version::VersionNumber).minor)
    end
    if version isa Tuple && length(version) == 2
        return Int(version[1]), Int(version[2])
    end
    if hasproperty(version, :major) && hasproperty(version, :minor)
        return Int(getproperty(version, :major)), Int(getproperty(version, :minor))
    end
    throw(ArgumentError("unsupported HTTP version value $(typeof(version))"))
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
not free or truncate the stored bytes. Collection-style operations expose the
remaining unread bytes.
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

function Base.String(body::BytesBody)
    remaining = (length(body.data) - body.next_index) + 1
    remaining <= 0 && return ""
    bytes = Vector{UInt8}(undef, remaining)
    copyto!(bytes, 1, body.data, body.next_index, remaining)
    return String(bytes)
end

@inline function Base.length(body::BytesBody)::Int
    return max(0, (length(body.data) - body.next_index) + 1)
end

Base.isempty(body::BytesBody)::Bool = length(body) == 0
Base.eltype(::Type{<:BytesBody}) = UInt8
Base.IteratorSize(::Type{<:BytesBody}) = Base.HasLength()
Base.IteratorEltype(::Type{<:BytesBody}) = Base.HasEltype()
Base.firstindex(::BytesBody) = 1
Base.lastindex(body::BytesBody) = length(body)

function Base.getindex(body::BytesBody, i::Integer)::UInt8
    index = Int(i)
    1 <= index <= length(body) || throw(BoundsError(body, i))
    return @inbounds body.data[body.next_index + index - 1]
end

function Base.iterate(body::BytesBody, state::Int=body.next_index)
    state > length(body.data) && return nothing
    return @inbounds(body.data[state]), state + 1
end

function Base.copy(body::BytesBody)::Vector{UInt8}
    remaining = length(body)
    remaining == 0 && return UInt8[]
    bytes = Vector{UInt8}(undef, remaining)
    copyto!(bytes, 1, body.data, body.next_index, remaining)
    return bytes
end

Base.convert(::Type{Vector{UInt8}}, body::BytesBody) = copy(body)
(::Type{Array})(body::BytesBody) = copy(body)
(::Type{Array{UInt8}})(body::BytesBody) = copy(body)
(::Type{Vector{UInt8}})(body::BytesBody) = copy(body)

Base.String(::EmptyBody) = ""

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

@inline _compat_body_arg(::Nothing) = EmptyBody()
@inline _compat_body_arg(body::AbstractBody) = body
@inline _compat_body_arg(body::AbstractVector{UInt8}) = BytesBody(body)
# Wrap String/SubString bodies in a BytesBody that aliases the underlying
# codeunits via the immutable string buffer — saves a length-of-body memcpy
# on every Response construction. Strings are immutable so this is safe even
# if the caller reuses the same String across multiple Responses; HTTP body
# write paths only read via copyto!/unsafe_write.
@inline _compat_body_arg(body::AbstractString) = BytesBody(codeunits(String(body)))

@inline _compat_body_length(::Nothing)::Int64 = Int64(0)
@inline _compat_body_length(::EmptyBody)::Int64 = Int64(0)
@inline _compat_body_length(body::BytesBody)::Int64 = Int64(max(0, length(body.data) - body.next_index + 1))
@inline _compat_body_length(body::AbstractVector{UInt8})::Int64 = Int64(length(body))
@inline _compat_body_length(body::AbstractString)::Int64 = Int64(ncodeunits(body))
@inline _compat_body_length(::AbstractBody)::Int64 = Int64(-1)

function _compat_body_arg(body)
    throw(ArgumentError("compat Request/Response constructors only support `nothing`, `HTTP.AbstractBody`, `AbstractString`, or `AbstractVector{UInt8}` bodies"))
end

@inline _response_body_arg(::Nothing) = EmptyBody()
@inline _response_body_arg(body::AbstractBody) = body
@inline _response_body_arg(body::AbstractVector{UInt8}) = body
@inline _response_body_arg(body::AbstractString) = _compat_body_arg(body)
_response_body_arg(body) = _compat_body_arg(body)

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

For migration from HTTP.jl 1.x, common positional forms such as
`Request(method, target, headers)` and `Request(method, target, headers, body)`
are still accepted. New code should use the keyword form above so body,
trailers, protocol metadata, and context ownership are explicit.
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

Request() = _request_nocopy("", "", Headers(), Headers(), EmptyBody(), nothing, Int64(-1), UInt8(1), UInt8(1), false, RequestContext())

function Request(
    method::AbstractString,
    target::AbstractString;
    headers=Headers(),
    trailers=Headers(),
    body=EmptyBody(),
    host::Union{Nothing,AbstractString}=nothing,
    content_length::Integer=Int64(-1),
    proto_major::Integer=1,
    proto_minor::Integer=1,
    close::Bool=false,
    context::RequestContext=RequestContext(),
)
    isempty(method) && throw(ArgumentError("method must not be empty"))
    isempty(target) && throw(ArgumentError("target must not be empty"))
    content_length < -1 && throw(ArgumentError("content_length must be >= -1"))
    (proto_major < 0 || proto_major > typemax(UInt8)) && throw(ArgumentError("proto_major must fit in UInt8"))
    (proto_minor < 0 || proto_minor > typemax(UInt8)) && throw(ArgumentError("proto_minor must fit in UInt8"))
    host_s = host === nothing ? nothing : String(host)
    actual_body = _compat_body_arg(body)
    actual_content_length = content_length < 0 ? _compat_body_length(body) : Int64(content_length)
    return Request{typeof(actual_body)}(
        String(method),
        String(target),
        copy(mkheaders(headers)),
        copy(mkheaders(trailers)),
        actual_body,
        host_s,
        actual_content_length,
        UInt8(proto_major),
        UInt8(proto_minor),
        close,
        context,
    )
end

function Request(
    method::AbstractString,
    target::AbstractString,
    headers;
    version=nothing,
    url=nothing,
    responsebody=nothing,
    parent=nothing,
    context=nothing,
)
    _ = url
    _ = responsebody
    _ = parent
    proto_major, proto_minor = _compat_proto_version(version)
    return Request(
        method,
        target;
        headers=headers,
        proto_major=proto_major,
        proto_minor=proto_minor,
        context=_compat_request_context(context),
    )
end

function Request(
    method::AbstractString,
    target::AbstractString,
    headers,
    body;
    version=nothing,
    url=nothing,
    responsebody=nothing,
    parent=nothing,
    context=nothing,
)
    _ = url
    _ = responsebody
    _ = parent
    proto_major, proto_minor = _compat_proto_version(version)
    return Request(
        method,
        target;
        headers=headers,
        body=_compat_body_arg(body),
        proto_major=proto_major,
        proto_minor=proto_minor,
        context=_compat_request_context(context),
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

"""
    get_request_context(request) -> RequestContext

Return the typed request context stored on `request`.

Use this helper when middleware or low-level code needs cancellation,
deadline, or timeout state. The legacy `request.context` property returns the
dict-like metadata view for compatibility with HTTP.jl 1.x code.
"""
@inline get_request_context(request::Request)::RequestContext = getfield(request, :context)

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

function Base.getproperty(request::Request, field::Symbol)
    field === :context && return _request_context_metadata!(getfield(request, :context))
    field === :version && return VersionNumber(Int(getfield(request, :proto_major)), Int(getfield(request, :proto_minor)))
    return getfield(request, field)
end

"""
    Response(status, body=EmptyBody(); reason="", headers=Headers(), trailers=Headers(),
             content_length=-1, proto_major=1, proto_minor=1, close=false,
             request=nothing)

HTTP response object shared by the client and server stacks.

Keyword arguments mirror `Request` closely. `request` optionally links the
response back to the originating request, which is especially useful in client
redirect flows and server handler pipelines.

Returns a new `Response{B}` where `B` is the stored body field type. Byte-vector
response bodies are retained as vectors so test fixtures can inspect
`response.body` directly; pass a `BytesBody` when cursor-based body reads are
desired. `request_url` is optional client metadata used by high-level request
helpers.

Throws `ArgumentError` for invalid status or protocol metadata.

For migration from HTTP.jl 1.x, common forms such as
`Response(status, headers, body)` and `Response(status, headers; body=...)`
are still accepted. New code should prefer `Response(status; headers=...,
body=..., content_length=...)`.
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
    response_body::B=EmptyBody();
    body=nobody,
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
    actual_body = body === nobody ? _response_body_arg(response_body) : _response_body_arg(body)
    actual_content_length = if content_length < 0
        body === nobody ? _compat_body_length(response_body) : _compat_body_length(body)
    else
        Int64(content_length)
    end
    status < 0 && throw(ArgumentError("status must be >= 0"))
    content_length < -1 && throw(ArgumentError("content_length must be >= -1"))
    redirect_count < 0 && throw(ArgumentError("redirect_count must be >= 0"))
    (proto_major < 0 || proto_major > typemax(UInt8)) && throw(ArgumentError("proto_major must fit in UInt8"))
    (proto_minor < 0 || proto_minor > typemax(UInt8)) && throw(ArgumentError("proto_minor must fit in UInt8"))
    return Response{typeof(actual_body)}(
        Int(status),
        String(reason),
        copy(mkheaders(headers)),
        copy(mkheaders(trailers)),
        actual_body,
        actual_content_length,
        UInt8(proto_major),
        UInt8(proto_minor),
        close,
        request,
        request_url === nothing ? nothing : String(request_url),
        previous,
        Int(redirect_count),
    )
end

Response() = Response(0)

Response(status::Int, body::AbstractString) = Response(status, BytesBody(Vector{UInt8}(codeunits(String(body)))))
Response(body::AbstractString) = Response(200, BytesBody(Vector{UInt8}(codeunits(String(body)))))
Response(body::AbstractVector{UInt8}) = Response(200, body)

function Response(
    status::Integer,
    headers,
    body;
    version=nothing,
    request=nothing,
)
    proto_major, proto_minor = _compat_proto_version(version)
    return Response(
        status,
        _response_body_arg(body);
        headers=headers,
        request=request,
        proto_major=proto_major,
        proto_minor=proto_minor,
    )
end

function Response(
    status::Integer,
    headers::Headers;
    body=nobody,
    request=nothing,
    version=nothing,
)
    proto_major, proto_minor = _compat_proto_version(version)
    compat_body = _response_body_arg(body)
    return Response(
        status,
        compat_body;
        headers=headers,
        request=request,
        proto_major=proto_major,
        proto_minor=proto_minor,
    )
end

function Response(
    status::Integer,
    headers::AbstractDict;
    body=nobody,
    request=nothing,
    version=nothing,
)
    proto_major, proto_minor = _compat_proto_version(version)
    compat_body = _response_body_arg(body)
    return Response(
        status,
        compat_body;
        headers=headers,
        request=request,
        proto_major=proto_major,
        proto_minor=proto_minor,
    )
end

function Response(
    status::Integer,
    headers::Tuple;
    body=nobody,
    request=nothing,
    version=nothing,
)
    proto_major, proto_minor = _compat_proto_version(version)
    compat_body = _response_body_arg(body)
    return Response(
        status,
        compat_body;
        headers=headers,
        request=request,
        proto_major=proto_major,
        proto_minor=proto_minor,
    )
end

function Response(
    status::Integer,
    headers::AbstractVector{<:Pair};
    body=nobody,
    request=nothing,
    version=nothing,
)
    proto_major, proto_minor = _compat_proto_version(version)
    compat_body = _response_body_arg(body)
    return Response(
        status,
        compat_body;
        headers=headers,
        request=request,
        proto_major=proto_major,
        proto_minor=proto_minor,
    )
end

function Response(
    status::Integer,
    headers::AbstractVector{<:Tuple};
    body=nobody,
    request=nothing,
    version=nothing,
)
    all(item -> length(item) == 2, headers) || throw(ArgumentError("invalid header list for compat Response constructor"))
    proto_major, proto_minor = _compat_proto_version(version)
    compat_body = _response_body_arg(body)
    return Response(
        status,
        compat_body;
        headers=headers,
        request=request,
        proto_major=proto_major,
        proto_minor=proto_minor,
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
Base.get(message::Union{Request,Response}, key::AbstractString, default) = get(message.headers, key, default)
Base.haskey(message::Union{Request,Response}, key::AbstractString) = haskey(message.headers, key)

function Base.getproperty(response::Response, field::Symbol)
    field === :url && return getfield(response, :request_url)
    field === :status_code && return getfield(response, :status)
    field === :version && return VersionNumber(Int(getfield(response, :proto_major)), Int(getfield(response, :proto_minor)))
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
