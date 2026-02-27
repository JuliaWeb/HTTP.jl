# String utilities for HTTP validation
# Port of aws-c-http/strutil.h, strutil.c

# HTTP token characters (RFC 7230 §3.2.6):
# token = 1*tchar
# tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." /
#          "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA

const _STRUTIL_TOKEN_CHARS = let
    s = Set{UInt8}()
    for c in UInt8('a'):UInt8('z'); push!(s, c); end
    for c in UInt8('A'):UInt8('Z'); push!(s, c); end
    for c in UInt8('0'):UInt8('9'); push!(s, c); end
    for c in UInt8.(['!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~'])
        push!(s, c)
    end
    s
end

"""
    strutil_is_http_token(s) -> Bool

Check if the string contains only valid HTTP token characters.
"""
function strutil_is_http_token(s::AbstractString)::Bool
    isempty(s) && return false
    for c in codeunits(s)
        c ∉ _STRUTIL_TOKEN_CHARS && return false
    end
    return true
end

"""
    strutil_is_http_field_value(s) -> Bool

Check if the string is a valid HTTP header field value (RFC 7230 §3.2).
Field values may contain VCHAR (visible chars), SP, HTAB, and obs-text.
"""
function strutil_is_http_field_value(s::AbstractString)::Bool
    for c in codeunits(s)
        # VCHAR: 0x21-0x7E, SP: 0x20, HTAB: 0x09, obs-text: 0x80-0xFF
        if c == 0x09 || c == 0x20 || (0x21 <= c <= 0x7E) || c >= 0x80
            continue
        end
        return false
    end
    return true
end

"""
    strutil_is_http_request_target(s) -> Bool

Check if the string is a valid HTTP request target.
Must not be empty and must not contain whitespace.
"""
function strutil_is_http_request_target(s::AbstractString)::Bool
    isempty(s) && return false
    for c in codeunits(s)
        # No whitespace or control characters
        if c <= 0x20 || c == 0x7F
            return false
        end
    end
    return true
end

"""
    strutil_is_http_pseudo_header_name(s) -> Bool

Check if a header name is an HTTP/2 pseudo-header (starts with ':').
"""
function strutil_is_http_pseudo_header_name(s::AbstractString)::Bool
    return !isempty(s) && s[1] == ':'
end

"""
    strutil_trim_http_whitespace(s) -> String

Trim optional whitespace (OWS) from an HTTP header value.
OWS is SP (0x20) or HTAB (0x09).
"""
function strutil_trim_http_whitespace(s::AbstractString)::String
    i = firstindex(s)
    j = lastindex(s)
    while i <= j && (s[i] == ' ' || s[i] == '\t')
        i = nextind(s, i)
    end
    while j >= i && (s[j] == ' ' || s[j] == '\t')
        j = prevind(s, j)
    end
    return i > j ? "" : s[i:j]
end

"""
    strutil_is_uppercase_http_method(s) -> Bool

Check if the string is a valid uppercase HTTP method.
"""
function strutil_is_uppercase_http_method(s::AbstractString)::Bool
    isempty(s) && return false
    for c in s
        if !isuppercase(c)
            return false
        end
    end
    return true
end

"""
    strutil_is_lowercase_http_header_name(s) -> Bool

Check if a header name is lowercase (required for HTTP/2).
Pseudo-headers start with ':' which is also acceptable.
"""
function strutil_is_lowercase_http_header_name(s::AbstractString)::Bool
    isempty(s) && return false
    for c in s
        if isuppercase(c)
            return false
        end
    end
    return true
end

# ─── Random access set ───

"""
    RandomAccessSet{T}

A data structure supporting O(1) add, O(1) remove, and O(1) random element access.
Implemented as a vector + dictionary for index tracking.
"""
mutable struct RandomAccessSet{T}
    elements::Vector{T}
    index_map::Dict{T, Int}
end

RandomAccessSet{T}() where {T} = RandomAccessSet{T}(T[], Dict{T, Int}())

function random_access_set_size(set::RandomAccessSet)::Int
    return length(set.elements)
end

function random_access_set_add!(set::RandomAccessSet{T}, element::T)::Bool where {T}
    haskey(set.index_map, element) && return false  # already present
    push!(set.elements, element)
    set.index_map[element] = length(set.elements)
    return true
end

function random_access_set_remove!(set::RandomAccessSet{T}, element::T)::Bool where {T}
    idx = get(set.index_map, element, 0)
    idx == 0 && return false

    # Swap with last element and pop
    last_element = set.elements[end]
    if idx != length(set.elements)
        set.elements[idx] = last_element
        set.index_map[last_element] = idx
    end
    pop!(set.elements)
    delete!(set.index_map, element)
    return true
end

function random_access_set_random(set::RandomAccessSet{T})::Union{T, Nothing} where {T}
    isempty(set.elements) && return nothing
    return set.elements[rand(1:length(set.elements))]
end

function random_access_set_contains(set::RandomAccessSet{T}, element::T)::Bool where {T}
    return haskey(set.index_map, element)
end

function random_access_set_clean_up!(set::RandomAccessSet)::Nothing
    empty!(set.elements)
    empty!(set.index_map)
    return nothing
end
