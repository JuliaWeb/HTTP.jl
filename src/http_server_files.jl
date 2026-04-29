mutable struct _SeekableResponseBody{I<:IO} <: AbstractBody
    io::I
    remaining::Int64
    owns_io::Bool
    @atomic closed::Bool
end

function body_closed(body::_SeekableResponseBody)::Bool
    return @atomic :acquire body.closed
end

function body_read!(body::_SeekableResponseBody, dst::Vector{UInt8})::Int
    body_closed(body) && return 0
    isempty(dst) && return 0
    if body.remaining <= 0
        body_close!(body)
        return 0
    end
    to_read = Int(min(Int64(length(dst)), body.remaining))
    n = readbytes!(body.io, dst, to_read)
    body.remaining -= n
    if n == 0 || body.remaining <= 0
        body_close!(body)
    end
    return n
end

function body_close!(body::_SeekableResponseBody)::Nothing
    body_closed(body) && return nothing
    @atomic :release body.closed = true
    if body.owns_io
        @try_ignore begin
            close(body.io)
        end
    end
    return nothing
end

struct _ServeContentRange
    start::Int64
    length::Int64
end

@inline function _servecontent_range_end(range::_ServeContentRange)::Int64
    return range.start + range.length - Int64(1)
end

@inline function _servecontent_content_range(range::_ServeContentRange, size::Int64)::String
    return "bytes $(range.start)-$(_servecontent_range_end(range))/$(size)"
end

const _SERVECONTENT_EXTENSION_MIME_TYPES = Dict{String,String}(
    ".css" => "text/css; charset=utf-8",
    ".csv" => "text/csv; charset=utf-8",
    ".gif" => "image/gif",
    ".htm" => "text/html; charset=utf-8",
    ".html" => "text/html; charset=utf-8",
    ".ico" => "image/x-icon",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".js" => "text/javascript; charset=utf-8",
    ".json" => "application/json; charset=utf-8",
    ".md" => "text/markdown; charset=utf-8",
    ".mjs" => "text/javascript; charset=utf-8",
    ".pdf" => "application/pdf",
    ".png" => "image/png",
    ".svg" => "image/svg+xml",
    ".txt" => "text/plain; charset=utf-8",
    ".wasm" => "application/wasm",
    ".webp" => "image/webp",
    ".woff" => "font/woff",
    ".woff2" => "font/woff2",
    ".xml" => "application/xml; charset=utf-8",
)

@inline function _servecontent_modtime(modtime::DateTime)::DateTime
    return Dates.floor(modtime, Dates.Second)
end

@inline function _format_http_date(modtime::DateTime)::String
    return Dates.format(_servecontent_modtime(modtime), Cookies.RFC1123GMTFormat)
end

function _parse_http_date(value::AbstractString)::Union{Nothing,DateTime}
    stripped = strip(value)
    isempty(stripped) && return nothing
    return Cookies._parse_http_gmt_datetime(stripped)
end

@inline function _servecontent_etag_body_start(value::AbstractString)::Int
    return startswith(value, "W/") ? 3 : 1
end

function _scan_http_etag(value::AbstractString)::Tuple{String,String}
    s = String(strip(String(value)))
    isempty(s) && return "", ""
    start = _servecontent_etag_body_start(s)
    start > lastindex(s) && return "", ""
    s[start] == '"' || return "", ""
    i = nextind(s, start)
    while i <= lastindex(s)
        c = s[i]
        if c == '"'
            remain_start = nextind(s, i)
            remain = remain_start > lastindex(s) ? "" : String(SubString(s, remain_start, lastindex(s)))
            return String(SubString(s, firstindex(s), i)), remain
        end
        (c == '!' || ('#' <= c <= '~') || UInt32(c) >= 0x80) || return "", ""
        i = nextind(s, i)
    end
    return "", ""
end

@inline function _etag_strong_match(a::String, b::String)::Bool
    return !isempty(a) && a == b && !startswith(a, "W/")
end

@inline function _etag_weak_match(a::String, b::String)::Bool
    return !isempty(a) && !isempty(b) && replace(a, "W/" => ""; count=1) == replace(b, "W/" => ""; count=1)
end

function _header_etag(headers::Headers)::String
    raw = header(headers, "ETag", "")
    isempty(raw) && return ""
    etag, remain = _scan_http_etag(raw)
    isempty(etag) && return ""
    isempty(strip(remain)) || return ""
    return etag
end

function _if_match_satisfied(request::Request, headers::Headers)::Union{Nothing,Bool}
    raw = header(request.headers, "If-Match", "")
    isempty(raw) && return nothing
    etag = _header_etag(headers)
    buf = raw
    while true
        buf = strip(buf)
        isempty(buf) && break
        if first(buf) == ','
            buf = String(SubString(buf, nextind(buf, firstindex(buf)), lastindex(buf)))
            continue
        end
        if first(buf) == '*'
            return true
        end
        candidate, remain = _scan_http_etag(buf)
        isempty(candidate) && break
        _etag_strong_match(candidate, etag) && return true
        buf = remain
    end
    return false
end

function _if_unmodified_since_satisfied(request::Request, modtime::Union{Nothing,DateTime})::Union{Nothing,Bool}
    raw = header(request.headers, "If-Unmodified-Since", "")
    (isempty(raw) || modtime === nothing) && return nothing
    parsed = _parse_http_date(raw)
    parsed === nothing && return nothing
    return _servecontent_modtime(modtime::DateTime) <= parsed::DateTime
end

function _if_none_match_satisfied(request::Request, headers::Headers)::Union{Nothing,Bool}
    raw = header(request.headers, "If-None-Match", "")
    isempty(raw) && return nothing
    etag = _header_etag(headers)
    buf = raw
    while true
        buf = strip(buf)
        isempty(buf) && break
        if first(buf) == ','
            buf = String(SubString(buf, nextind(buf, firstindex(buf)), lastindex(buf)))
            continue
        end
        if first(buf) == '*'
            return false
        end
        candidate, remain = _scan_http_etag(buf)
        isempty(candidate) && break
        _etag_weak_match(candidate, etag) && return false
        buf = remain
    end
    return true
end

function _if_modified_since_satisfied(request::Request, modtime::Union{Nothing,DateTime})::Union{Nothing,Bool}
    (request.method == "GET" || request.method == "HEAD") || return nothing
    raw = header(request.headers, "If-Modified-Since", "")
    (isempty(raw) || modtime === nothing) && return nothing
    parsed = _parse_http_date(raw)
    parsed === nothing && return nothing
    return _servecontent_modtime(modtime::DateTime) > parsed::DateTime
end

function _if_range_satisfied(request::Request, headers::Headers, modtime::Union{Nothing,DateTime})::Union{Nothing,Bool}
    (request.method == "GET" || request.method == "HEAD") || return nothing
    raw = header(request.headers, "If-Range", "")
    isempty(raw) && return nothing
    etag, remain = _scan_http_etag(raw)
    if !isempty(etag) && isempty(strip(remain))
        return _etag_strong_match(etag, _header_etag(headers))
    end
    modtime === nothing && return false
    parsed = _parse_http_date(raw)
    parsed === nothing && return false
    return _servecontent_modtime(modtime::DateTime) == parsed::DateTime
end

function _servecontent_preconditions(
    request::Request,
    response_headers::Headers,
    modtime::Union{Nothing,DateTime},
)::Tuple{Symbol,String}
    if_match = _if_match_satisfied(request, response_headers)
    if if_match === nothing
        if_unmodified = _if_unmodified_since_satisfied(request, modtime)
        if if_unmodified === false
            return :precondition_failed, ""
        end
    elseif if_match === false
        return :precondition_failed, ""
    end

    if_none = _if_none_match_satisfied(request, response_headers)
    if if_none === false
        if request.method == "GET" || request.method == "HEAD"
            return :not_modified, ""
        end
        return :precondition_failed, ""
    elseif if_none === nothing
        if_modified = _if_modified_since_satisfied(request, modtime)
        if if_modified === false
            return :not_modified, ""
        end
    end

    range_header = header(request.headers, "Range", "")
    if !isempty(range_header)
        if_range = _if_range_satisfied(request, response_headers, modtime)
        if if_range === false
            range_header = ""
        end
    end
    return :ok, range_header
end

function _parse_single_range(range_header::AbstractString, size::Int64)::Union{Nothing,_ServeContentRange,Symbol}
    isempty(range_header) && return nothing
    startswith(range_header, "bytes=") || return :invalid
    specs = filter(!isempty, map(strip, split(String(SubString(String(range_header), 7)), ',')))
    length(specs) == 1 || return :invalid
    spec = specs[1]
    dash = findfirst(isequal('-'), spec)
    dash === nothing && return :invalid
    start_raw = dash == firstindex(spec) ? "" : String(SubString(spec, firstindex(spec), prevind(spec, dash)))
    end_raw = dash == lastindex(spec) ? "" : String(SubString(spec, nextind(spec, dash), lastindex(spec)))
    if isempty(start_raw)
        isempty(end_raw) && return :invalid
        suffix = try
            parse(Int64, end_raw)
        catch
            return :invalid
        end
        suffix < 0 && return :invalid
        suffix == 0 && return _ServeContentRange(size, 0)
        suffix > size && (suffix = size)
        start = size - suffix
        return _ServeContentRange(start, size - start)
    end
    start = try
        parse(Int64, start_raw)
    catch
        return :invalid
    end
    start < 0 && return :invalid
    start >= size && return :no_overlap
    if isempty(end_raw)
        return _ServeContentRange(start, size - start)
    end
    finish = try
        parse(Int64, end_raw)
    catch
        return :invalid
    end
    finish < start && return :invalid
    finish >= size && (finish = size - 1)
    return _ServeContentRange(start, (finish - start) + 1)
end

function _servecontent_extension_type(name::AbstractString)::Union{Nothing,String}
    slash = _find_last_ascii_delim(name, 0x2f)
    dot = _find_last_ascii_delim(name, 0x2e)
    (dot == 0 || dot <= slash) && return nothing
    ext = lowercase(String(SubString(name, dot, lastindex(name))))
    return get(() -> nothing, _SERVECONTENT_EXTENSION_MIME_TYPES, ext)
end

@inline function _servefile_content_type(name::AbstractString)::String
    ext_type = _servecontent_extension_type(name)
    return ext_type === nothing ? "application/octet-stream" : (ext_type::String)
end

function _sniff_content_type_source(source::AbstractVector{UInt8})::String
    isempty(source) && return "application/octet-stream"
    limit = min(length(source), 512)
    return sniff(@view(source[1:limit]))
end

function _sniff_content_type_source(source::IO)::String
    seekstart(source)
    bytes = read(source, 512)
    return isempty(bytes) ? "application/octet-stream" : sniff(bytes)
end

function _servecontent_content_type(source, name::AbstractString, provided::Union{Nothing,AbstractString})::String
    provided === nothing || return String(provided)
    ext_type = _servecontent_extension_type(name)
    ext_type === nothing || return ext_type::String
    return _sniff_content_type_source(source)
end

function _source_size(source::AbstractVector{UInt8}, size::Union{Nothing,Integer})::Int64
    if size !== nothing
        Int64(size) == length(source) || throw(ArgumentError("size did not match source length"))
        return Int64(size)
    end
    return Int64(length(source))
end

function _source_size(source::IO, size::Union{Nothing,Integer})::Int64
    size !== nothing && return Int64(size)
    try
        seekend(source)
        total = position(source)
        seekstart(source)
        return Int64(total)
    catch err
        throw(ArgumentError("servecontent requires a seekable source or explicit size: $(sprint(showerror, err))"))
    end
end

function _not_modified_headers(headers::Headers)::Headers
    result = copy(headers)
    removeheader(result, "Content-Type")
    removeheader(result, "Content-Length")
    removeheader(result, "Content-Encoding")
    if hasheader(result, "ETag")
        removeheader(result, "Last-Modified")
    end
    return result
end

function _servecontent_body(source::AbstractVector{UInt8}, total_size::Int64, range::Union{Nothing,_ServeContentRange})
    range === nothing && return BytesBody(source), total_size
    (range:: _ServeContentRange).length <= 0 && return EmptyBody(), Int64(0)
    first_idx = Int(range.start + 1)
    last_idx = Int(range.start + range.length)
    return BytesBody(@view(source[first_idx:last_idx])), range.length
end

function _servecontent_body(source::IO, total_size::Int64, range::Union{Nothing,_ServeContentRange})
    if range === nothing
        seekstart(source)
        return _SeekableResponseBody(source, total_size, false, false), total_size
    end
    selected = range::_ServeContentRange
    seek(source, selected.start)
    return _SeekableResponseBody(source, selected.length, false, false), selected.length
end

"""
    servecontent(request, source; ...)

Build a response for `request` from byte-backed or seekable content while
handling conditional headers and single-byte-range requests.

`source` may be an `AbstractVector{UInt8}` or a seekable `IO`. The helper sets
`Content-Type`, `Content-Length`, `Last-Modified`, `ETag`, `Accept-Ranges`, and
`Content-Range` when enough information is provided. It returns `304`, `412`,
or `416` responses for the corresponding precondition/range outcomes.
"""
function servecontent(
    request::Request,
    source;
    name::AbstractString="",
    size::Union{Nothing,Integer}=nothing,
    modtime::Union{Nothing,DateTime}=nothing,
    content_type::Union{Nothing,AbstractString}=nothing,
    etag::Union{Nothing,AbstractString}=nothing,
    headers=Headers(),
    allow_ranges::Bool=true,
)::Response
    response_headers = copy(mkheaders(headers))
    modtime_value = modtime === nothing ? nothing : _servecontent_modtime(modtime::DateTime)
    etag === nothing || setheader(response_headers, "ETag", String(etag))
    modtime_value === nothing || setheader(response_headers, "Last-Modified", _format_http_date(modtime_value::DateTime))

    precondition_result, range_header = _servecontent_preconditions(request, response_headers, modtime_value)
    if precondition_result == :precondition_failed
        return Response(
            412,
            EmptyBody();
            headers=response_headers,
            content_length=0,
            proto_major=Int(request.proto_major),
            proto_minor=Int(request.proto_minor),
            request=request,
        )
    elseif precondition_result == :not_modified
        return Response(
            304,
            EmptyBody();
            headers=_not_modified_headers(response_headers),
            content_length=0,
            proto_major=Int(request.proto_major),
            proto_minor=Int(request.proto_minor),
            request=request,
        )
    end

    total_size = _source_size(source, size)
    total_size >= 0 || throw(ArgumentError("servecontent size must be >= 0"))
    resolved_type = _servecontent_content_type(source, name, content_type)
    setheader(response_headers, "Content-Type", resolved_type)

    status = 200
    selected_range = nothing
    if allow_ranges
        setheader(response_headers, "Accept-Ranges", "bytes")
        if !isempty(range_header)
            parsed_range = _parse_single_range(range_header, total_size)
            if parsed_range === :invalid || (parsed_range === :no_overlap && total_size > 0)
                setheader(response_headers, "Content-Range", "bytes */$(total_size)")
                return Response(
                    416,
                    EmptyBody();
                    headers=response_headers,
                    content_length=0,
                    proto_major=Int(request.proto_major),
                    proto_minor=Int(request.proto_minor),
                    request=request,
                )
            elseif parsed_range isa _ServeContentRange
                range = parsed_range::_ServeContentRange
                if range.length > 0
                    status = 206
                    selected_range = range
                    setheader(response_headers, "Content-Range", _servecontent_content_range(range, total_size))
                end
            end
        end
    end

    body, selected_length = _servecontent_body(source, total_size, selected_range)
    setheader(response_headers, "Content-Length", string(selected_length))
    return Response(
        status,
        body;
        headers=response_headers,
        content_length=selected_length,
        proto_major=Int(request.proto_major),
        proto_minor=Int(request.proto_minor),
        request=request,
    )
end

function _request_path_and_query(target::AbstractString)::Tuple{String,String}
    raw = String(target)
    isempty(raw) && return "/", ""
    if raw == "*"
        return "/", ""
    end
    path_and_query = if startswith(raw, "/")
        raw
    else
        scheme_idx = findfirst("://", raw)
        if scheme_idx === nothing
            raw
        else
            authority_start = last(scheme_idx) + 1
            authority_start > lastindex(raw) ? "/" : begin
                slash_idx = findnext(isequal('/'), raw, authority_start)
                slash_idx === nothing ? "/" : String(SubString(raw, slash_idx, lastindex(raw)))
            end
        end
    end
    qidx = findfirst(isequal('?'), path_and_query)
    if qidx === nothing
        return path_and_query, ""
    end
    path = qidx == firstindex(path_and_query) ? "" : String(SubString(path_and_query, firstindex(path_and_query), prevind(path_and_query, qidx)))
    query = String(SubString(path_and_query, qidx, lastindex(path_and_query)))
    return isempty(path) ? "/" : path, query
end

function _decoded_request_path_segments(path::AbstractString)::Vector{String}
    decoded = try
        URIs.unescapeuri(String(path))
    catch
        throw(ArgumentError("invalid request path"))
    end
    segments = String[]
    for segment in split(decoded, '/'; keepempty=false)
        (segment == "." || segment == "..") && throw(ArgumentError("invalid request path"))
        push!(segments, segment)
    end
    return segments
end

function _join_request_path(root::String, segments::Vector{String})::String
    path = root
    @inbounds for segment in segments
        path = joinpath(path, segment)
    end
    return path
end

function _fileserver_spa_fallback_path(root_path::String, spa_fallback::Union{Nothing,AbstractString})::Union{Nothing,String}
    spa_fallback === nothing && return nothing
    segments = _decoded_request_path_segments("/" * String(spa_fallback))
    isempty(segments) && throw(ArgumentError("fileserver spa_fallback must resolve to an existing file within root"))
    resolved = _join_request_path(root_path, segments)
    isfile(resolved) || throw(ArgumentError("fileserver spa_fallback must resolve to an existing file within root"))
    return resolved
end

@inline function _find_last_ascii_delim(s::AbstractString, delim::UInt8)::Int
    bytes = codeunits(s)
    @inbounds for i in length(bytes):-1:1
        bytes[i] == delim && return i
    end
    return 0
end

@inline function _looks_like_file_request_path(path::AbstractString)::Bool
    slash = _find_last_ascii_delim(path, 0x2f)
    dot = _find_last_ascii_delim(path, 0x2e)
    return dot != 0 && dot > slash
end

function _server_response(
    request::Request,
    status::Integer,
    headers=Headers(),
    body::AbstractBody=EmptyBody(),
    content_length::Integer=0,
)::Response
    return Response(
        status,
        body;
        headers=headers,
        content_length=content_length,
        proto_major=Int(request.proto_major),
        proto_minor=Int(request.proto_minor),
        request=request,
    )
end

function _redirect_response(request::Request, location::AbstractString)::Response
    headers = Headers()
    setheader(headers, "Location", String(location))
    return _server_response(request, 301, headers)
end

function _method_not_allowed_response(request::Request)::Response
    headers = Headers()
    setheader(headers, "Allow", "GET, HEAD")
    return _server_response(request, 405, headers)
end

function _resolve_file_etag(path::String, st, etag)
    etag === nothing && return nothing
    if etag === :weak_stat
        return "W/\"$(st.size)-$(round(Int64, st.mtime))\""
    end
    if etag isa Function
        value = etag(path, st)
        value === nothing && return nothing
        return String(value)
    end
    return String(etag)
end

function _servefile_response(
    request::Request,
    path::String,
    request_path::String,
    query_suffix::String,
    index_file::String,
    redirect_canonical::Bool,
    etag=nothing,
    cache_control::Union{Nothing,AbstractString}=nothing,
)::Response
    if redirect_canonical && endswith(request_path, "/" * index_file)
        location = String(SubString(request_path, firstindex(request_path), lastindex(request_path) - length(index_file)))
        return _redirect_response(request, location * query_suffix)
    end

    if isdir(path)
        if redirect_canonical && !endswith(request_path, "/")
            return _redirect_response(request, request_path * "/" * query_suffix)
        end
        path = joinpath(path, index_file)
        isfile(path) || return _server_response(request, 404)
    else
        if redirect_canonical && request_path != "/" && endswith(request_path, "/")
            trimmed = rstrip(request_path, '/')
            isempty(trimmed) && (trimmed = "/")
            return _redirect_response(request, trimmed * query_suffix)
        end
        isfile(path) || return _server_response(request, 404)
    end

    st = stat(path)
    modtime = Dates.unix2datetime(st.mtime)
    response_headers = Headers()
    cache_control === nothing || setheader(response_headers, "Cache-Control", String(cache_control))
    resolved_etag = _resolve_file_etag(path, st, etag)
    source = Base.open(path, "r")
    response = servecontent(
        request,
        source;
        name=basename(path),
        size=st.size,
        modtime=modtime,
        content_type=_servefile_content_type(path),
        etag=resolved_etag,
        headers=response_headers,
    )
    if response.body isa _SeekableResponseBody
        (response.body::_SeekableResponseBody).owns_io = true
    end
    return response
end

"""
    servefile(request, path; ...)

Serve the file or directory at `path` for `request` using `servecontent`
semantics and canonical redirect handling.

Only `GET` and `HEAD` are served. Directory requests resolve `index_file`;
missing files return `404`, and unsafe or invalid request paths return `400`.
"""
function servefile(
    request::Request,
    path::AbstractString;
    index_file::AbstractString="index.html",
    redirect_canonical::Bool=true,
    etag=nothing,
    cache_control::Union{Nothing,AbstractString}=nothing,
)::Response
    (request.method == "GET" || request.method == "HEAD") || return _method_not_allowed_response(request)
    request_path, query_suffix = _request_path_and_query(request.target)
    try
        _decoded_request_path_segments(request_path)
    catch
        return _server_response(request, 400)
    end
    return _servefile_response(
        request,
        String(path),
        request_path,
        query_suffix,
        String(index_file),
        redirect_canonical,
        etag,
        cache_control,
    )
end

"""
    fileserver(root; ...)

Return a request handler that serves static files rooted at `root`.

If `spa_fallback` is provided, missing request paths whose final segment does
not look like a filename are served from that file within `root`. Missing
asset-like paths still return `404`.

The returned function is a normal `Request -> Response` handler suitable for
`serve!`, routers, and middleware.
"""
function fileserver(
    root::AbstractString;
    index_file::AbstractString="index.html",
    redirect_canonical::Bool=true,
    etag=nothing,
    cache_control::Union{Nothing,AbstractString}=nothing,
    spa_fallback::Union{Nothing,AbstractString}=nothing,
)
    root_path = abspath(String(root))
    isdir(root_path) || throw(ArgumentError("fileserver root must be an existing directory"))
    index_name = String(index_file)
    spa_fallback_path = _fileserver_spa_fallback_path(root_path, spa_fallback)
    return function (request::Request)
        (request.method == "GET" || request.method == "HEAD") || return _method_not_allowed_response(request)
        request_path, query_suffix = _request_path_and_query(request.target)
        segments = try
            _decoded_request_path_segments(request_path)
        catch
            return _server_response(request, 400)
        end
        resolved = isempty(segments) ? root_path : _join_request_path(root_path, segments)
        response = _servefile_response(
            request,
            resolved,
            request_path,
            query_suffix,
            index_name,
            redirect_canonical,
            etag,
            cache_control,
        )
        if response.status == 404 && spa_fallback_path !== nothing && !_looks_like_file_request_path(request_path)
            return _servefile_response(
                request,
                spa_fallback_path::String,
                request_path,
                query_suffix,
                index_name,
                false,
                etag,
                cache_control,
            )
        end
        return response
    end
end
