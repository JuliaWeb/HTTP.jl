__precompile__()
module Requests

export URI, FileParam, headers, cookies, statuscode, post, requestfor
export get_streaming, post_streaming, write_chunked
export view, save
export set_proxy, set_https_proxy, get_request_settings

import Base: get, write

if VERSION < v"0.5.0-dev+1229"
    import Base.FS: File
else
    import Base.Filesystem: File
end

import URIParser: URI
import HttpCommon: Cookie

using Compat
using HttpParser
using HttpCommon
using URIParser
using MbedTLS
using Codecs
using JSON
using Libz

const CRLF = "\r\n"

include("parsing.jl")
include("multipart.jl")
include("streaming.jl")
include("mimetypes.jl")

function __init__()
    __init_parsing__()
    __init_streaming__()
    init_proxy()
end

type GlobalSettings
    http_proxy::Nullable{URI}
    https_proxy::Nullable{URI}
    max_redirects::Int
end
GlobalSettings() = GlobalSettings(Nullable{URI}(), Nullable{URI}(), 5)

function Base.show(io::IO, settings::GlobalSettings)
    println(io, "HTTP proxy: ", isnull(settings.http_proxy) ? "No proxy" : get(settings.http_proxy))
    println(io, "HTTPS proxy: ", isnull(settings.https_proxy) ? "No proxy" : get(settings.https_proxy))
    print(io, "Max redirects: ", settings.max_redirects)
end

const SETTINGS = GlobalSettings()

function init_proxy()
    if haskey(ENV, "http_proxy")
        try
            proxy = ENV["http_proxy"]
            set_proxy(proxy)
            info("Using proxy $proxy from http_proxy environment variable")
        catch err
            warn("Problem parsing http_proxy environment variable $(ENV["http_proxy"]); ignoring\n $err")
        end
    end
    if haskey(ENV, "https_proxy")
        try
            proxy = ENV["https_proxy"]
            set_https_proxy(proxy)
            info("Using HTTPS proxy $proxy from https_proxy environment variable")
        catch err
            warn("Problem parsing https_proxy environment variable $(ENV["https_proxy"]); ignoring\n $err")
        end
    end
end

set_proxy(proxy::URI) = set_proxy(Nullable(proxy))
set_proxy(proxy::Nullable{URI}) = SETTINGS.http_proxy = proxy
set_proxy(proxy) = set_proxy(URI(proxy))
set_https_proxy(proxy) = SETTINGS.https_proxy=Nullable(URI(proxy))

get_request_settings() = SETTINGS

## Convenience methods for extracting the payload of a response
for kind in [:Response, :Request]
    @eval bytes(r::$kind) = r.data
    @eval text(r::$kind) = Compat.String(bytes(r))
    @eval Base.bytestring(r::$kind) = text(r)
    @eval Base.readall(r::$kind) = text(r)
    @eval Base.read(r::$kind) = bytes(r)
    @eval json(r::$kind; kwargs...) = JSON.parse(text(r); kwargs...)

    ## Response getters to future-proof against changes to the Response type
    @eval headers(r::$kind) = r.headers
end

cookies(r::Response) = r.cookies
statuscode(r::Response) = r.status

function requestfor(r::Response)
    isnull(r.request) && error("No associated request for response")
    get(r.request)
end

history(r::Response) = r.history


# Stolen from https://github.com/dcjones/Gadfly.jl/blob/7fd56991e55b6617d37d7e3d0d69a310bdd36b05/src/Gadfly.jl#L1016
function open_file(filename)
    if OS_NAME == :Darwin
        run(`open $(filename)`)
    elseif OS_NAME == :Linux || OS_NAME == :FreeBSD
        run(`xdg-open $(filename)`)
    elseif OS_NAME == :Windows
        run(`$(ENV["COMSPEC"]) /c start $(filename)`)
    end
end

function mimetype(r::Response)
    if haskey(headers(r), "Content-Type")
        ct = split(headers(r)["Content-Type"], ";")[1]
        return Nullable(ct)
    else
        return Nullable{Compat.UTF8String}()
    end
end

function contentdisposition(r::Response)
    if haskey(headers(r), "Content-Disposition")
        cd = split(headers(r)["Content-Disposition"], ";")
        if length(cd) ≥ 2
            filepart = split(cd[2], "=", limit=2)
            if length(filepart) == 2
                return  filepart[2] |> strip |> f->strip(f, '"') |> Nullable
            end
        end
    end
    return Nullable{Compat.UTF8String}()
end

"""
`save(r::Response, path=".")`

Saves the data in the response in the directory `path`. If the path is a directory,
then the filename is automatically chosen based on the response headers.

Returns the full pathname of the saved file.
"""
function save(r::Response, path=".")
    if !isdir(path)
        filename = path
    else
        maybe_basename = contentdisposition(r)
        if !isnull(maybe_basename)
            filename = joinpath(path, get(maybe_basename))
        else
            ext = "txt"
            maybe_mt = mimetype(r)
            if !isnull(maybe_mt)
                mt = get(maybe_mt)
                if haskey(MIMETYPES, mt)
                    ext = MIMETYPES[mt]
                else
                    if '/' ∉ mt
                        ext = mt
                    end
                end
            end
            basefile = Dates.format(now(), "mm-dd-yyyy-H-M")
            filename = joinpath(path, "$basefile.$ext")
        end
    end
    open(filename, "w") do file
        write(file, bytes(r))
    end
    filename
end

"""
`view(r::Response)`

View the data in the response with whatever application is associated with
its mimetype.
"""
function view(r::Response)
    path = save(r, mktempdir())
    open_file(path)
end

http_port(uri) = uri.port == 0 ? 80 : uri.port
https_port(uri) = uri.port == 0 ? 443 : uri.port

function default_request(method,resource,host,data,user_headers=Dict{Union{},Union{}}())
    headers = Dict(
        "User-Agent" => "Requests.jl/0.0.0",
        "Host" => host,
        "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        )
    if !isempty(data)
        headers["Content-Length"] = dec(sizeof(data))
    end
    merge!(headers,user_headers)
    Request(method,resource,headers,data)
end

function resourcefor(uri::URI)
    r = uri.path
    if !isempty(uri.query)
        r = "$r?$(uri.query)"
    end
    r
end

function default_request(uri::URI,headers,data,method)
    resource = resourcefor(uri)
    if !isempty(uri.userinfo) && !haskey(headers,"Authorization")
        headers["Authorization"] = "Basic $(String(encode(Base64, uri.userinfo)))"
    end
    host = uri.port == 0 ? uri.host : "$(uri.host):$(uri.port)"
    request = default_request(method,resource,host,data,headers)
    request.uri = uri
    return request
end

scheme(uri::URI) = isdefined(uri, :scheme) ? uri.scheme : uri.schema

function format_query_str(queryparams; uri = URI(""))
    query_str = isempty(uri.query) ? string() : string(uri.query, "&")

    for (k, v) in queryparams
        if isa(v, Array)
            query_str *= join(map(vi -> "$(URIParser.escape(string(k)))=$(URIParser.escape(string(vi)))", v), "&") * "&"
        else
            query_str *= "$(URIParser.escape(string(k)))=$(URIParser.escape(string(v)))&"
        end
    end
    chop(query_str) # remove the trailing &
end


timeout_in_sec(::Void) = Inf
timeout_in_sec(t::Dates.TimePeriod) = Dates.toms(t)/1000.
timeout_in_sec(t) = convert(Float64, t)

cookie_value(c::Cookie) = c.value
cookie_value(s) = s
function cookie_request_header(d::Dict)
    join(["$key=$(cookie_value(val))" for (key,val) in d], ';')
end
cookie_request_header(cookies::AbstractVector{Cookie}) =
    cookie_request_header(Dict([Pair(cookie.name, cookie.value) for cookie in cookies]))

const is_location = r"^location$"i

function get_redirect_uri(response)
    300 <= statuscode(response) < 400 || return Nullable{URI}()
    hdrs = headers(response)
    for (key, val) in hdrs
        if is_location(key)
            uri = URI(val)
            if isempty(uri.host)  # Redirect URL was given as a relative path
                request = requestfor(response)
                uri = URI(request.uri.scheme, request.uri.host, request.uri.port, uri.path, uri.query)
            end
            return Nullable(uri)
        end
    end
    return Nullable{URI}()
end

immutable RedirectException <: Exception
    max_redirects::Int
end

function Base.show(io::IO, err::RedirectException)
    print(io, "RedirectException: more than $(err.max_redirects) redirects attempted.")
end

macro check_body()
  has_body = esc(:has_body)
  quote
    write_body || error("Incompatible arguments: write_body cannot be false if a data argument is provided.")
    $has_body && error("Multiple body options specified. Please only specify one")
    $has_body = true
  end
end

function do_request(uri::URI, verb; kwargs...)
    response_stream = do_stream_request(uri, verb; kwargs...)
    response = response_stream.response
    response.data = read(response_stream)
    if get(response.headers, "Content-Encoding", "") ∈ ("gzip", "deflate")
        if !isempty(response.data)
            response.data = response.data |> ZlibInflateInputStream |> read
        end
    end
    response
end

parse_request_data(data) = (data, "application/octet-stream")
parse_request_data(data::Associative) =
  (format_query_str(data), "application/x-www-form-urlencoded")

function do_stream_request(uri::URI, verb; headers = Dict{AbstractString, AbstractString}(),
                            cookies = nothing,
                            data = nothing,
                            json = nothing,
                            files = FileParam[],
                            timeout = nothing,
                            query::Dict = Dict(),
                            allow_redirects = true,
                            max_redirects = SETTINGS.max_redirects,
                            history = Response[],
                            tls_conf = TLS_VERIFY,
                            write_body = true,
                            proxy = SETTINGS.http_proxy,
                            https_proxy = SETTINGS.https_proxy
                            )

    query_str = format_query_str(query; uri = uri)
    newuri = URI(uri; query = query_str)
    timeout_sec = timeout_in_sec(timeout)

    body = ""
    has_body = false
    if json ≠ nothing
        @check_body
        if get(headers,"Content-Type","application/json") != "application/json"
            error("Tried to send json data with incompatible Content-Type")
        end
        headers["Content-Type"] = "application/json"
        body = JSON.json(json)
    end

    if data ≠ nothing
        @check_body
        body, default_content_type = parse_request_data(data)
        if "Content-Type" ∉ keys(headers)
            headers["Content-Type"] = default_content_type
        end
    end

    if cookies ≠ nothing
        headers["Cookie"] = cookie_request_header(cookies)
    end

    request = default_request(newuri, headers, body, verb)
    if isempty(files)
        response_stream = open_stream(request, tls_conf, timeout_sec, proxy, https_proxy)
        if write_body
            write(response_stream, request.data)
        end
    else
        @check_body
        verb == "POST" || error("Multipart file post only supported with POST")
        if haskey(headers,"Content-Type") && !beginswith(headers["Content-Type"],"multipart/form-data")
            error("Tried to send form data with invalid Content-Type. ")
        end
        multipart_settings = prepare_multipart_request!(request, files)
        response_stream = open_stream(request, tls_conf, timeout_sec, proxy, https_proxy)
        send_multipart(response_stream, multipart_settings, files)
    end
    main_task = current_task()
    @schedule begin
        try
            process_response(response_stream)
        catch err
            Base.throwto(main_task, err)
        end
        while response_stream.state < BodyDone
            wait(response_stream)
        end
        if response_stream.state != UpgradeConnection
            close(response_stream)
        end
    end
    if write_body
        while response_stream.state < HeadersDone
            wait(response_stream)
        end
        response_stream.response.history = history
        if allow_redirects && verb ≠ :head
            redirect_uri = get_redirect_uri(response_stream)
            if !isnull(redirect_uri)
                length(response_stream.response.history) > max_redirects &&
                    throw(RedirectException(max_redirects))
                push!(history, response_stream.response)
                return do_stream_request(get(redirect_uri), verb; headers=headers,
                     data=data, json=json, files=files, timeout=timeout,
                     allow_redirects=allow_redirects, max_redirects=max_redirects,
                     history=history, tls_conf=tls_conf)
            end
        end

    end
    return response_stream
end

for f in [:get, :post, :put, :delete, :head,
          :trace, :options, :patch, :connect]
    f_str = uppercase(string(f))
    f_stream = Symbol(string(f, "_streaming"))
    @eval begin
        function ($f)(uri::URI, data::AbstractString; headers::Dict=Dict())
            do_request(uri, $f_str; data=data, headers=headers)
        end
        function ($f_stream)(uri::URI, data::AbstractString; headers::Dict=Dict())
            do_stream_request(uri, $f_str; data=data, headers=headers)
        end

        ($f)(uri::AbstractString; args...) = ($f)(URI(uri); args...)
        ($f)(uri::URI; args...) = do_request(uri, $f_str; args...)

        ($f_stream)(uri::AbstractString; args...) = ($f_stream)(URI(uri); args...)
        ($f_stream)(uri::URI; args...) = do_stream_request(uri, $f_str; args...)
    end
end

end
