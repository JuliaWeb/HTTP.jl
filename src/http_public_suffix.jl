# Public suffix lookup table and walker, ported from golang.org/x/net/publicsuffix.
#
# Copyright 2012 The Go Authors. All rights reserved.
# Use of the source/data is governed by a BSD-style license included at
# http_public_suffix_data/LICENSE.
#
# The lookup tables in http_public_suffix_data/ are copied from the Go
# package's generated data files:
# https://github.com/golang/net/tree/master/publicsuffix
#
# Go reference revision: 9e7fdbfadb32b0cc7524100014c5cf9b6adc7729
# PSL snapshot: publicsuffix.org public_suffix_list.dat,
# git revision d6c92f1bbb7433e5db7b8405c25d4035fb8ff376
# (2026-02-06T07:36:33Z).

const _PUBLIC_SUFFIX_VERSION =
    "publicsuffix.org public_suffix_list.dat, git revision d6c92f1bbb7433e5db7b8405c25d4035fb8ff376 (2026-02-06T07:36:33Z)"

const _PS_NODES_BITS = 40
const _PS_NODES_BITS_CHILDREN = 10
const _PS_NODES_BITS_ICANN = 1
const _PS_NODES_BITS_TEXT_OFFSET = 16
const _PS_NODES_BITS_TEXT_LENGTH = 6

const _PS_CHILDREN_BITS_WILDCARD = 1
const _PS_CHILDREN_BITS_NODE_TYPE = 2
const _PS_CHILDREN_BITS_HI = 14
const _PS_CHILDREN_BITS_LO = 14

const _PS_NODE_TYPE_NORMAL = UInt32(0)
const _PS_NODE_TYPE_EXCEPTION = UInt32(1)
const _PS_NUM_TLD = UInt32(1450)
const _PS_NOT_FOUND = typemax(UInt32)

const _PublicSuffixData = NamedTuple{(:text, :nodes, :children),Tuple{String,Vector{UInt8},Vector{UInt8}}}
const _PUBLIC_SUFFIX_DATA_LOCK = ReentrantLock()
const _PUBLIC_SUFFIX_DATA = Ref{Union{Nothing,_PublicSuffixData}}(nothing)

@inline _ps_mask(bits::Integer) = (UInt64(1) << bits) - UInt64(1)

function _public_suffix_data()
    data = _PUBLIC_SUFFIX_DATA[]
    data !== nothing && return data
    lock(_PUBLIC_SUFFIX_DATA_LOCK)
    try
        data = _PUBLIC_SUFFIX_DATA[]
        if data === nothing
            dir = joinpath(@__DIR__, "http_public_suffix_data")
            data = (
                text = read(joinpath(dir, "text"), String),
                nodes = read(joinpath(dir, "nodes")),
                children = read(joinpath(dir, "children")),
            )
            _PUBLIC_SUFFIX_DATA[] = data
        end
        return data
    finally
        unlock(_PUBLIC_SUFFIX_DATA_LOCK)
    end
end

@inline function _ps_get_uint32(data::Vector{UInt8}, i::UInt32)::UInt32
    off = Int(i) * 4 + 1
    return UInt32(@inbounds data[off + 3]) |
           (UInt32(@inbounds data[off + 2]) << 8) |
           (UInt32(@inbounds data[off + 1]) << 16) |
           (UInt32(@inbounds data[off]) << 24)
end

@inline function _ps_get_uint40(data::Vector{UInt8}, i::UInt32)::UInt64
    off = Int(i) * (_PS_NODES_BITS ÷ 8) + 1
    return UInt64(@inbounds data[off + 4]) |
           (UInt64(@inbounds data[off + 3]) << 8) |
           (UInt64(@inbounds data[off + 2]) << 16) |
           (UInt64(@inbounds data[off + 1]) << 24) |
           (UInt64(@inbounds data[off]) << 32)
end

function _ps_node_label(data, i::UInt32)::SubString{String}
    x = _ps_get_uint40(data.nodes, i)
    len = Int(x & _ps_mask(_PS_NODES_BITS_TEXT_LENGTH))
    x >>= _PS_NODES_BITS_TEXT_LENGTH
    offset = Int(x & _ps_mask(_PS_NODES_BITS_TEXT_OFFSET))
    return SubString(data.text, offset + 1, offset + len)
end

function _ps_find(data, label::AbstractString, lo::UInt32, hi::UInt32)::UInt32
    while lo < hi
        mid = lo + (hi - lo) ÷ UInt32(2)
        node_label = _ps_node_label(data, mid)
        if node_label < label
            lo = mid + UInt32(1)
        elseif node_label == label
            return mid
        else
            hi = mid
        end
    end
    return _PS_NOT_FOUND
end

function _ps_last_dot_byte(s::String)::Int
    bytes = codeunits(s)
    for i in length(bytes):-1:1
        @inbounds bytes[i] == UInt8('.') && return i - 1
    end
    return -1
end

function _ps_prefix_before_dot(s::String, dot0::Int)::String
    dot0 <= 0 && return ""
    return String(@view(codeunits(s)[1:dot0]))
end

function _ps_suffix_from_byte(domain::String, suffix0::Int)::String
    start = suffix0 + 1
    start <= ncodeunits(domain) || return ""
    return String(@view(codeunits(domain)[start:end]))
end

function _public_suffix(domain::String)::String
    data = _public_suffix_data()
    lo = UInt32(0)
    hi = _PS_NUM_TLD
    s = domain
    suffix0 = ncodeunits(domain)
    icann_node = false
    wildcard = false
    while true
        dot0 = _ps_last_dot_byte(s)
        if wildcard
            suffix0 = 1 + dot0
        end
        lo == hi && break
        label = _ps_suffix_from_byte(s, dot0 + 1)
        f = _ps_find(data, label, lo, hi)
        f == _PS_NOT_FOUND && break

        u = _ps_get_uint40(data.nodes, f) >> (_PS_NODES_BITS_TEXT_OFFSET + _PS_NODES_BITS_TEXT_LENGTH)
        icann_node = (u & _ps_mask(_PS_NODES_BITS_ICANN)) != 0
        u >>= _PS_NODES_BITS_ICANN
        child_index = UInt32(u & _ps_mask(_PS_NODES_BITS_CHILDREN))
        cu = _ps_get_uint32(data.children, child_index)
        lo = cu & UInt32(_ps_mask(_PS_CHILDREN_BITS_LO))
        cu >>= _PS_CHILDREN_BITS_LO
        hi = cu & UInt32(_ps_mask(_PS_CHILDREN_BITS_HI))
        cu >>= _PS_CHILDREN_BITS_HI
        node_type = cu & UInt32(_ps_mask(_PS_CHILDREN_BITS_NODE_TYPE))
        if node_type == _PS_NODE_TYPE_NORMAL
            suffix0 = 1 + dot0
        elseif node_type == _PS_NODE_TYPE_EXCEPTION
            suffix0 = 1 + ncodeunits(s)
            break
        end
        cu >>= _PS_CHILDREN_BITS_NODE_TYPE
        wildcard = (cu & UInt32(_ps_mask(_PS_CHILDREN_BITS_WILDCARD))) != 0

        dot0 == -1 && break
        s = _ps_prefix_before_dot(s, dot0)
    end
    if suffix0 == ncodeunits(domain)
        dot0 = _ps_last_dot_byte(domain)
        return _ps_suffix_from_byte(domain, dot0 + 1)
    end
    return _ps_suffix_from_byte(domain, suffix0)
end
