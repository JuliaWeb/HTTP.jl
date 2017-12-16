# compression detection
const ZIP = UInt8[0x50, 0x4b, 0x03, 0x04]
const GZIP = UInt8[0x1f, 0x8b, 0x08]

iscompressed(bytes::Vector{UInt8}) = length(bytes) > 3 && (all(bytes[1:4] .== ZIP) || all(bytes[1:3] .== GZIP))
iscompressed(str::String) = iscompressed(Vector{UInt8}(str))
iscompressed(f::FIFOBuffer) = iscompressed(String(f))
iscompressed(d::Dict) = false
iscompressed(d) = false

# Based on the net/http/sniff.go implementation of DetectContentType
# sniff implements the algorithm described
# at http://mimesniff.spec.whatwg.org/ to determine the
# Content-Type of the given data. It considers at most the
# first 512 bytes of data. sniff always returns
# a valid MIME type: if it cannot determine a more specific one, it
# returns "application/octet-stream".
const MAXSNIFFLENGTH = 512
const WHITESPACE = Set{UInt8}([UInt8('\t'),UInt8('\n'),UInt8('\u0c'),UInt8('\r'),UInt8(' ')])

"""
`HTTP.sniff(content::Union{Vector{UInt8}, String, IO})` => `String` (mimetype)

`HTTP.sniff` will look at the first 512 bytes of `content` to try and determine a valid mimetype.
If a mimetype can't be determined appropriately, `"application/octet-stream"` is returned.

Supports JSON detection through the `HTTP.isjson(content)` function.
"""
function sniff end

function sniff(body::IO)
    alreadymarked = ismarked(body)
    mark(body)
    data = read(body, MAXSNIFFLENGTH)
    reset(body)
    alreadymarked && mark(body)
    return sniff(data)
end

sniff(str::String) = sniff(Vector{UInt8}(str)[1:min(length(Vector{UInt8}(str)), MAXSNIFFLENGTH)])
sniff(f::FIFOBuffer) = sniff(String(f))

function sniff(data::Vector{UInt8})
    firstnonws = 1
    while firstnonws < length(data) && data[firstnonws] in WHITESPACE
        firstnonws += 1
    end

    for sig in SNIFF_SIGNATURES
        ismatch(sig, data, firstnonws) && return contenttype(sig)
    end
    return "application/octet-stream" # fallback
end

struct Exact
    sig::Vector{UInt8}
    contenttype::String
end
contenttype(e::Exact) = e.contenttype

function ismatch(e::Exact, data::Vector{UInt8}, firstnonws)
    length(data) < length(e.sig) && return false
    for i = 1:length(e.sig)
        e.sig[i] == data[i] || return false
    end
    return true
end

struct Masked
    mask::Vector{UInt8}
    pat::Vector{UInt8}
    skipws::Bool
    contenttype::String
end
Masked(mask::Vector{UInt8}, pat::Vector{UInt8}, contenttype::String) = Masked(mask, pat, false, contenttype)

contenttype(m::Masked) = m.contenttype

function ismatch(m::Masked, data::Vector{UInt8}, firstnonws)
    # pattern matching algorithm section 6
    # https://mimesniff.spec.whatwg.org/#pattern-matching-algorithm
    sk = (m.skipws ? firstnonws : 1) - 1
    length(m.pat) != length(m.mask) && return false
    length(data) < length(m.mask) && return false
    for (i, mask) in enumerate(m.mask)
        (data[i+sk] & mask) != m.pat[i] && return false
    end
    return true
end

struct HTMLSig
    html::Vector{UInt8}
    HTMLSig(str::String) = new(Vector{UInt8}(str))
end

contenttype(h::HTMLSig) = "text/html; charset=utf-8"

function ismatch(h::HTMLSig, data::Vector{UInt8}, firstnonws)
    length(data) < length(h.html)+1 && return false
    for (i, b) in enumerate(h.html)
        db = data[i+firstnonws-1]
        (UInt8('A') <= b && b <= UInt8('Z')) && (db &= 0xDF)
        b != db && return false
    end
    data[length(h.html)+firstnonws] in (UInt8(' '), UInt8('>')) || return false
    return true
end

struct MP4Sig end
contenttype(::Type{MP4Sig}) = "video/mp4"

function byteequal(data1, data2, len)
    for i = 1:len
        data1[i] == data2[i] || return false
    end
    return true
end

const mp4ftype = Vector{UInt8}("ftyp")
const mp4 = Vector{UInt8}("mp4")

# Byte swap int
bigend(b) = UInt32(b[4]) | UInt32(b[3])<<8 | UInt32(b[2])<<16 | UInt32(b[1])<<24

function ismatch(::Type{MP4Sig}, data::Vector{UInt8}, firstnonws)
    # https://mimesniff.spec.whatwg.org/#signature-for-mp4
    # c.f. section 6.2.1
    length(data) < 12 && return false
    boxsize = Int(bigend(data))
    (boxsize % 4 != 0 || length(data) < boxsize) && return false
    byteequal(view(data, 5:9), mp4ftype, 4) || return false
    for st = 9:4:boxsize+1
        st == 13 && continue
        byteequal(view(data, st:st+3), mp4, 3) && return true
    end
    return false
end

struct TextSig end
contenttype(::Type{TextSig}) = "text/plain; charset=utf-8"

function ismatch(::Type{TextSig}, data::Vector{UInt8}, firstnonws)
    # c.f. section 5, step 4.
    for i = firstnonws:min(length(data),MAXSNIFFLENGTH)
        b = data[i]
        (b <= 0x08 || b == 0x0B ||
        0x0E <= b <= 0x1A ||
        0x1C <= b <= 0x1F) && return false
    end
    return true
end

struct JSONSig end
contenttype(::Type{JSONSig}) = "application/json; charset=utf-8"

ismatch(::Type{JSONSig}, data::Vector{UInt8}, firstnonws) = isjson(data)[1]

const DISPLAYABLE_TYPES = ["text/html; charset=utf-8",
                    "text/plain; charset=utf-8",
                    "application/json; charset=utf-8",
                    "text/xml; charset=utf-8",
                    "text/plain; charset=utf-16be",
                    "text/plain; charset=utf-16le"]

# Data matching the table in section 6.
const SNIFF_SIGNATURES = [
    HTMLSig("<!DOCTYPE HTML"),
    HTMLSig("<HTML"),
    HTMLSig("<HEAD"),
    HTMLSig("<SCRIPT"),
    HTMLSig("<IFRAME"),
    HTMLSig("<H1"),
    HTMLSig("<DIV"),
    HTMLSig("<FONT"),
    HTMLSig("<TABLE"),
    HTMLSig("<A"),
    HTMLSig("<STYLE"),
    HTMLSig("<TITLE"),
    HTMLSig("<B"),
    HTMLSig("<BODY"),
    HTMLSig("<BR"),
    HTMLSig("<P"),
    HTMLSig("<!--"),
    Masked([0xff,0xff,0xff,0xff,0xff], Vector{UInt8}("<?xml"), true, "text/xml; charset=utf-8"),
    Exact(Vector{UInt8}("%PDF-"), "application/pdf"),
    Exact(Vector{UInt8}("%!PS-Adobe-"), "application/postscript"),

    # UTF BOMs.
    Masked([0xFF,0xFF,0x00,0x00], [0xFE,0xFF,0x00,0x00], "text/plain; charset=utf-16be"),
    Masked([0xFF,0xFF,0x00,0x00], [0xFF,0xFE,0x00,0x00], "text/plain; charset=utf-16le"),
    Masked([0xFF,0xFF,0xFF,0x00], [0xEF,0xBB,0xBF,0x00], "text/plain; charset=utf-8"),

    Exact(Vector{UInt8}("GIF87a"), "image/gif"),
    Exact(Vector{UInt8}("GIF89a"), "image/gif"),
    Exact([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A], "image/png"),
    Exact([0xFF,0xD8,0xFF], "image/jpeg"),
    Exact(Vector{UInt8}("BM"), "image/bmp"),
    Masked([0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF],
           UInt8['R','I','F','F',0x00,0x00,0x00,0x00,'W','E','B','P','V','P'],
           "image/webp"),
    Exact([0x00,0x00,0x01,0x00], "image/vnd.microsoft.icon"),
    Masked([0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0xFF,0xFF,0xFF,0xFF],
           UInt8['R','I','F','F',0x00,0x00,0x00,0x00,'W','A','V','E'],
           "audio/wave"),
    Masked([0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0xFF,0xFF,0xFF,0xFF],
           UInt8['F','O','R','M',0x00,0x00,0x00,0x00,'A','I','F','F'],
           "audio/aiff"),
    Masked([0xFF,0xFF,0xFF,0xFF],
           Vector{UInt8}(".snd"),
           "audio/basic"),
    Masked(UInt8['O','g','g','S',0x00],
           UInt8[0x4F,0x67,0x67,0x53,0x00],
           "application/ogg"),
    Masked([0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF],
           UInt8['M','T','h','d',0x00,0x00,0x00,0x06],
           "audio/midi"),
    Masked([0xFF,0xFF,0xFF],
           Vector{UInt8}("ID3"),
           "audio/mpeg"),
    Masked([0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0xFF,0xFF,0xFF,0xFF],
           UInt8['R','I','F','F',0x00,0x00,0x00,0x00,'A','V','I',' '],
        "video/avi"),
    Exact([0x1A,0x45,0xDF,0xA3], "video/webm"),
    Exact([0x52,0x61,0x72,0x20,0x1A,0x07,0x00], "application/x-rar-compressed"),
    Exact([0x50,0x4B,0x03,0x04], "application/zip"),
    Exact([0x1F,0x8B,0x08], "application/x-gzip"),
    MP4Sig,
    JSONSig,
    TextSig, # should be last
]

function ignorewhitespace(bytes, i, maxlen)
    while true
        eof, b, i = nextbyte(bytes, i, maxlen)
        eof && return true, b, i
        b in WHITESPACE || return false, b, i
    end
end

function nextbyte(bytes, i, maxlen)
    i += 1
    i >= maxlen && return true, 0x00, i
    @inbounds b = bytes[i]
    return false, b, i
end

function restofstring(bytes, i, maxlen)
    while true
        eof, b, i = nextbyte(bytes, i, maxlen)
        eof && return i
        b == DOUBLE_QUOTE && return i
        if b == ESCAPE
            eof, b, i = nextbyte(bytes, i, maxlen)
        end
    end
end

macro expect(ch)
    return esc(quote
        eof, b, i = ignorewhitespace(bytes, i, maxlen)
        eof && return true, i
        b == $ch || return false, i
    end)
end

const OPEN_CURLY_BRACE  = UInt8('{')
const CLOSE_CURLY_BRACE  = UInt8('}')
const OPEN_SQUARE_BRACE  = UInt8('[')
const CLOSE_SQUARE_BRACE  = UInt8(']')
const DOUBLE_QUOTE  = UInt8('"')
const ESCAPE        = UInt8('\\')
const COMMA = UInt8(',')
const COLON = UInt8(':')
const ZERO = UInt8('0')
const NINE = UInt8('9')
const LITTLE_N = UInt8('n')
const LITTLE_U = UInt8('u')
const LITTLE_L = UInt8('l')
const LITTLE_T = UInt8('t')
const LITTLE_R = UInt8('r')
const LITTLE_E = UInt8('e')
const LITTLE_F = UInt8('f')
const LITTLE_A = UInt8('a')
const LITTLE_S = UInt8('s')
const PERIOD = UInt8('.')
const REF = @uninit Vector{Ptr{UInt8}}(uninitialized, 1)

function isjson(bytes, i=0, maxlen=min(length(bytes), MAXSNIFFLENGTH))
    # ignore leading whitespace
    isempty(bytes) && return false, 0
    eof, b, i = ignorewhitespace(bytes, i, maxlen)
    eof && return true, i
    # must start with:
    if b == OPEN_CURLY_BRACE
        # '{' start of object
        # must then read a string key, potential whitespace, then colon, potential whitespace then recursively check `isjson`
        while true
            @expect DOUBLE_QUOTE
            i = restofstring(bytes, i, maxlen)
            @expect COLON
            ret, i = isjson(bytes, i, maxlen)
            ret || return false, i
            eof, b, i = ignorewhitespace(bytes, i, maxlen)
            (eof || b == CLOSE_CURLY_BRACE) && return true, i
            b != COMMA && return false, i
        end
    elseif b == OPEN_SQUARE_BRACE
        # '[' start of array
        # peek at next byte to check for empty array
        ia = i
        eof, b, i = nextbyte(bytes, i, maxlen)
        if b != CLOSE_SQUARE_BRACE
            i = ia
            # recursively check `isjson`, then potential whitespace, then ',' or ']'
            while true
                ret, i = isjson(bytes, i, maxlen)
                ret || return false, i
                eof, b, i = ignorewhitespace(bytes, i, maxlen)
                (eof || b == CLOSE_SQUARE_BRACE) && return true, i
                b != COMMA && return false, i
            end
        end
    elseif b == DOUBLE_QUOTE
        # '"' start of string
        # must read until end of string w/ potential escaped '"'
        i = restofstring(bytes, i, maxlen)
    elseif ZERO <= b <= NINE
        # must read until end of number
        v = zero(Float64)
        ptr = pointer(bytes) + i - 1
        v = ccall(:jl_strtod_c, Float64, (Ptr{UInt8}, Ptr{Ptr{UInt8}}), ptr, REF)
        i += REF[1] - ptr - 1
    elseif b == LITTLE_N
        # null
        @expect LITTLE_U
        @expect LITTLE_L
        @expect LITTLE_L
    elseif b == LITTLE_T
        # true
        @expect LITTLE_R
        @expect LITTLE_U
        @expect LITTLE_E
    elseif b == LITTLE_F
        # false
        @expect LITTLE_A
        @expect LITTLE_L
        @expect LITTLE_S
        @expect LITTLE_E
    else
        return false, i
    end
    return true, i
end
