# Content sniffing helpers used by multipart/form request bodies.

const _SNIFF_MAX_LENGTH = 512
const _SNIFF_WHITESPACE = Set{UInt8}([UInt8('\t'), UInt8('\n'), UInt8('\u000c'), UInt8('\r'), UInt8(' ')])
const _SNIFF_REF = Vector{Ptr{UInt8}}(undef, 1)

@inline function _sniff_code_units(data)
    return data isa AbstractVector{UInt8} ? data : collect(data)
end

function _sniff_ignore_whitespace(bytes::AbstractVector{UInt8}, i::Int, maxlen::Int)
    while true
        eof, b, i = _sniff_next_byte(bytes, i, maxlen)
        eof && return true, b, i
        b in _SNIFF_WHITESPACE || return false, b, i
    end
end

function _sniff_next_byte(bytes::AbstractVector{UInt8}, i::Int, maxlen::Int)
    i += 1
    i >= maxlen && return true, 0x00, i
    return false, @inbounds(bytes[i]), i
end

function _sniff_rest_of_string(bytes::AbstractVector{UInt8}, i::Int, maxlen::Int)
    while true
        eof, b, i = _sniff_next_byte(bytes, i, maxlen)
        eof && return i
        b == UInt8('"') && return i
        if b == UInt8('\\')
            eof, b, i = _sniff_next_byte(bytes, i, maxlen)
            _ = eof
            _ = b
        end
    end
end

macro _sniff_expect(ch)
    return esc(quote
        eof, b, i = _sniff_ignore_whitespace(bytes, i, maxlen)
        eof && return true, i
        b == $ch || return false, i
    end)
end

function isjson(bytes, i::Int=0, maxlen::Int=min(length(bytes), _SNIFF_MAX_LENGTH))
    isempty(bytes) && return false, 0
    eof, b, i = _sniff_ignore_whitespace(bytes, i, maxlen)
    eof && return true, i
    if b == UInt8('{')
        while true
            @_sniff_expect UInt8('"')
            i = _sniff_rest_of_string(bytes, i, maxlen)
            @_sniff_expect UInt8(':')
            ret, i = isjson(bytes, i, maxlen)
            ret || return false, i
            eof, b, i = _sniff_ignore_whitespace(bytes, i, maxlen)
            (eof || b == UInt8('}')) && return true, i
            b == UInt8(',') || return false, i
        end
    elseif b == UInt8('[')
        array_index = i
        eof, b, i = _sniff_next_byte(bytes, i, maxlen)
        if b != UInt8(']')
            i = array_index
            while true
                ret, i = isjson(bytes, i, maxlen)
                ret || return false, i
                eof, b, i = _sniff_ignore_whitespace(bytes, i, maxlen)
                (eof || b == UInt8(']')) && return true, i
                b == UInt8(',') || return false, i
            end
        end
    elseif b == UInt8('"')
        i = _sniff_rest_of_string(bytes, i, maxlen)
    elseif (UInt8('0') <= b <= UInt8('9')) || b == UInt8('-')
        ptr = pointer(bytes) + i - 1
        ccall(:jl_strtod_c, Float64, (Ptr{UInt8}, Ptr{Ptr{UInt8}}), ptr, _SNIFF_REF)
        i += Int(_SNIFF_REF[1] - ptr - 1)
    elseif b == UInt8('n')
        @_sniff_expect UInt8('u')
        @_sniff_expect UInt8('l')
        @_sniff_expect UInt8('l')
    elseif b == UInt8('t')
        @_sniff_expect UInt8('r')
        @_sniff_expect UInt8('u')
        @_sniff_expect UInt8('e')
    elseif b == UInt8('f')
        @_sniff_expect UInt8('a')
        @_sniff_expect UInt8('l')
        @_sniff_expect UInt8('s')
        @_sniff_expect UInt8('e')
    else
        return false, i
    end
    return true, i
end

struct _SniffExact
    sig::Vector{UInt8}
    content_type::String
end

struct _SniffMasked
    mask::Vector{UInt8}
    pat::Vector{UInt8}
    skipws::Bool
    content_type::String
end

_SniffMasked(mask::Vector{UInt8}, pat::Vector{UInt8}, content_type::String) = _SniffMasked(mask, pat, false, content_type)

struct _SniffHTMLSig
    html::Vector{UInt8}
end

struct _SniffMP4Sig end
struct _SniffTextSig end
struct _SniffJSONSig end

function _sniff_content_type(sig::_SniffExact)::String
    return sig.content_type
end

function _sniff_content_type(sig::_SniffMasked)::String
    return sig.content_type
end

function _sniff_content_type(::_SniffHTMLSig)::String
    return "text/html; charset=utf-8"
end

function _sniff_content_type(::_SniffMP4Sig)::String
    return "video/mp4"
end

function _sniff_content_type(::_SniffTextSig)::String
    return "text/plain; charset=utf-8"
end

function _sniff_content_type(::_SniffJSONSig)::String
    return "application/json; charset=utf-8"
end

function _sniff_match(sig::_SniffExact, data::AbstractVector{UInt8}, firstnonws::Int)::Bool
    _ = firstnonws
    length(data) < length(sig.sig) && return false
    for i in eachindex(sig.sig)
        @inbounds sig.sig[i] == data[i] || return false
    end
    return true
end

function _sniff_match(sig::_SniffMasked, data::AbstractVector{UInt8}, firstnonws::Int)::Bool
    offset = (sig.skipws ? firstnonws : 1) - 1
    length(sig.pat) == length(sig.mask) || return false
    length(data) < length(sig.mask) + offset && return false
    for (i, mask) in enumerate(sig.mask)
        @inbounds((data[i+offset] & mask) == sig.pat[i]) || return false
    end
    return true
end

function _sniff_match(sig::_SniffHTMLSig, data::AbstractVector{UInt8}, firstnonws::Int)::Bool
    length(data) < length(sig.html) + firstnonws && return false
    for (i, b) in enumerate(sig.html)
        @inbounds db = data[i+firstnonws-1]
        if UInt8('A') <= b <= UInt8('Z')
            db &= 0xDF
        end
        b == db || return false
    end
    @inbounds return data[length(sig.html)+firstnonws] in (UInt8(' '), UInt8('>'))
end

function _byte_equal(data1::AbstractVector{UInt8}, ind::Int, data2::Vector{UInt8})::Bool
    for i in eachindex(data2)
        @inbounds data1[ind+i-1] == data2[i] || return false
    end
    return true
end

const _SNIFF_MP4_FTYP = collect(codeunits("ftyp"))
const _SNIFF_MP4 = collect(codeunits("mp4"))

function _big_endian_u32(bytes::AbstractVector{UInt8})::UInt32
    return UInt32(bytes[4]) | UInt32(bytes[3]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 24
end

function _sniff_match(::_SniffMP4Sig, data::AbstractVector{UInt8}, firstnonws::Int)::Bool
    _ = firstnonws
    length(data) < 12 && return false
    boxsize = Int(_big_endian_u32(data))
    (boxsize % 4 != 0 || length(data) < boxsize) && return false
    _byte_equal(data, 5, _SNIFF_MP4_FTYP) || return false
    for st in 9:4:(boxsize+1)
        st == 13 && continue
        _byte_equal(data, st, _SNIFF_MP4) && return true
    end
    return false
end

function _sniff_match(::_SniffTextSig, data::AbstractVector{UInt8}, firstnonws::Int)::Bool
    for i in firstnonws:min(length(data), _SNIFF_MAX_LENGTH)
        @inbounds b = data[i]
        ((b <= 0x08) || b == 0x0B || (0x0E <= b <= 0x1A) || (0x1C <= b <= 0x1F)) && return false
    end
    return true
end

function _sniff_match(::_SniffJSONSig, data::AbstractVector{UInt8}, firstnonws::Int)::Bool
    matched, i = isjson(data, firstnonws - 1)
    matched || return false
    # A valid JSON *prefix* is not enough: e.g. "2A" parses the leading number
    # but leaves trailing bytes. Require the remainder (within the sniff window)
    # to be whitespace only, otherwise it isn't JSON.
    stop = min(length(data), _SNIFF_MAX_LENGTH)
    @inbounds for j in (i + 1):stop
        data[j] in _SNIFF_WHITESPACE || return false
    end
    return true
end

const _SNIFF_SIGNATURES = Any[
    _SniffHTMLSig(collect(codeunits("<!DOCTYPE HTML"))),
    _SniffHTMLSig(collect(codeunits("<HTML"))),
    _SniffHTMLSig(collect(codeunits("<HEAD"))),
    _SniffHTMLSig(collect(codeunits("<SCRIPT"))),
    _SniffHTMLSig(collect(codeunits("<IFRAME"))),
    _SniffHTMLSig(collect(codeunits("<H1"))),
    _SniffHTMLSig(collect(codeunits("<DIV"))),
    _SniffHTMLSig(collect(codeunits("<FONT"))),
    _SniffHTMLSig(collect(codeunits("<TABLE"))),
    _SniffHTMLSig(collect(codeunits("<A"))),
    _SniffHTMLSig(collect(codeunits("<STYLE"))),
    _SniffHTMLSig(collect(codeunits("<TITLE"))),
    _SniffHTMLSig(collect(codeunits("<B"))),
    _SniffHTMLSig(collect(codeunits("<BODY"))),
    _SniffHTMLSig(collect(codeunits("<BR"))),
    _SniffHTMLSig(collect(codeunits("<P"))),
    _SniffHTMLSig(collect(codeunits("<!--"))),
    _SniffMasked(UInt8[0xff, 0xff, 0xff, 0xff, 0xff], collect(codeunits("<?xml")), true, "text/xml; charset=utf-8"),
    _SniffExact(collect(codeunits("%PDF-")), "application/pdf"),
    _SniffExact(collect(codeunits("%!PS-Adobe-")), "application/postscript"),
    _SniffMasked(UInt8[0xFF, 0xFF, 0x00, 0x00], UInt8[0xFE, 0xFF, 0x00, 0x00], "text/plain; charset=utf-16be"),
    _SniffMasked(UInt8[0xFF, 0xFF, 0x00, 0x00], UInt8[0xFF, 0xFE, 0x00, 0x00], "text/plain; charset=utf-16le"),
    _SniffMasked(UInt8[0xFF, 0xFF, 0xFF, 0x00], UInt8[0xEF, 0xBB, 0xBF, 0x00], "text/plain; charset=utf-8"),
    _SniffExact(collect(codeunits("GIF87a")), "image/gif"),
    _SniffExact(collect(codeunits("GIF89a")), "image/gif"),
    _SniffExact(UInt8[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "image/png"),
    _SniffExact(UInt8[0xFF, 0xD8, 0xFF], "image/jpeg"),
    _SniffExact(collect(codeunits("BM")), "image/bmp"),
    _SniffMasked(
        UInt8[0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
        UInt8['R', 'I', 'F', 'F', 0x00, 0x00, 0x00, 0x00, 'W', 'E', 'B', 'P', 'V', 'P'],
        "image/webp",
    ),
    _SniffExact(UInt8[0x00, 0x00, 0x01, 0x00], "image/vnd.microsoft.icon"),
    _SniffMasked(
        UInt8[0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF],
        UInt8['R', 'I', 'F', 'F', 0x00, 0x00, 0x00, 0x00, 'W', 'A', 'V', 'E'],
        "audio/wave",
    ),
    _SniffMasked(
        UInt8[0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF],
        UInt8['F', 'O', 'R', 'M', 0x00, 0x00, 0x00, 0x00, 'A', 'I', 'F', 'F'],
        "audio/aiff",
    ),
    _SniffMasked(UInt8[0xFF, 0xFF, 0xFF, 0xFF], collect(codeunits(".snd")), "audio/basic"),
    _SniffMasked(UInt8['O', 'g', 'g', 'S', 0x00], UInt8[0x4F, 0x67, 0x67, 0x53, 0x00], "application/ogg"),
    _SniffMasked(UInt8[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], UInt8['M', 'T', 'h', 'd', 0x00, 0x00, 0x00, 0x06], "audio/midi"),
    _SniffMasked(UInt8[0xFF, 0xFF, 0xFF], collect(codeunits("ID3")), "audio/mpeg"),
    _SniffMasked(
        UInt8[0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF],
        UInt8['R', 'I', 'F', 'F', 0x00, 0x00, 0x00, 0x00, 'A', 'V', 'I', ' '],
        "video/avi",
    ),
    _SniffExact(UInt8[0x1A, 0x45, 0xDF, 0xA3], "video/webm"),
    _SniffExact(UInt8[0x52, 0x61, 0x72, 0x20, 0x1A, 0x07, 0x00], "application/x-rar-compressed"),
    _SniffExact(UInt8[0x50, 0x4B, 0x03, 0x04], "application/zip"),
    _SniffExact(UInt8[0x1F, 0x8B, 0x08], "application/x-gzip"),
    _SniffMP4Sig(),
    _SniffJSONSig(),
    _SniffTextSig(),
]

function sniff(data::AbstractString)::String
    bytes = collect(codeunits(String(data)))
    return sniff(bytes)
end

function sniff(io::IO)::String
    marked = ismarked(io)
    mark(io)
    data = read(io, _SNIFF_MAX_LENGTH)
    reset(io)
    marked && mark(io)
    return sniff(data)
end

function sniff(data::AbstractVector{UInt8})::String
    bytes = _sniff_code_units(data)
    firstnonws = 1
    while firstnonws < length(bytes) && bytes[firstnonws] in _SNIFF_WHITESPACE
        firstnonws += 1
    end
    for sig in _SNIFF_SIGNATURES
        _sniff_match(sig, bytes, firstnonws) && return _sniff_content_type(sig)
    end
    return "application/octet-stream"
end
