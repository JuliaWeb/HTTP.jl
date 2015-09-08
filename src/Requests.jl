# __precompile__(false)
module Requests

import Base: get, write
import Base.FS: File

using HttpParser
using HttpCommon
using URIParser
using MbedTLS
using Codecs
using JSON
using Zlib

export URI, FileParam, headers, cookies, statuscode, post, requestfor, requestsfor

# Datatype Tuples for the different `cfunction` signatures used by `HttpParser`
const HTTP_CB      = (Int, (Ptr{Parser},))
const HTTP_DATA_CB = (Int, (Ptr{Parser}, Ptr{Cchar}, Csize_t,))

function __init__()
    # Turn all the callbacks into C callable functions.
    global const on_message_begin_cb = cfunction(on_message_begin, HTTP_CB...)
    global const on_url_cb = cfunction(on_url, HTTP_DATA_CB...)
    global const on_status_complete_cb = cfunction(on_status_complete, HTTP_CB...)
    global const on_header_field_cb = cfunction(on_header_field, HTTP_DATA_CB...)
    global const on_header_value_cb = cfunction(on_header_value, HTTP_DATA_CB...)
    global const on_headers_complete_cb = cfunction(on_headers_complete, HTTP_CB...)
    global const on_body_cb = cfunction(on_body, HTTP_DATA_CB...)
    global const on_message_complete_cb = cfunction(on_message_complete, HTTP_CB...)

    global const TLS_VERIFY = get_default_tls_config(true)
    global const TLS_NOVERIFY = get_default_tls_config(false)
end

## Convenience methods for extracting the payload of a response
bytes(r::Response) = r.data
text(r::Response) = utf8(bytes(r))
Base.bytestring(r::Response) = text(r)
json(r::Response; kwargs...) = JSON.parse(text(r); kwargs...)

## Response getters to future-proof against changes to the Response type
headers(r::Response) = r.headers
headers(r::Request) = r.eaders
cookies(r::Response) = r.cookies
statuscode(r::Response) = r.status

requestfor(r::Response) = r.requests[end]
requestsfor(r::Response) = r.requests

## URI Parsing

const CRLF = "\r\n"

import URIParser: URI
import HttpCommon: Cookie

function send_request(response_stream)
    socket = response_stream.socket
    request = requestfor(response_stream)
    print(socket,request.method, " ", isempty(request.resource) ? "/" : request.resource,
          " HTTP/1.1", CRLF,
          map(h->string(h,": ",request.headers[h],CRLF), collect(keys(request.headers)))...,
          "", CRLF)
    write(socket, request.data)
    write(socket, CRLF)
end

function default_request(method,resource,host,data,user_headers=Dict{None,None}())
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

function default_request(uri::URI,headers,data,method)
    resource = uri.path
    if uri.query != ""
        resource = resource*"?"*uri.query
    end
    if uri.userinfo != "" && !haskey(headers,"Authorization")
        headers["Authorization"] = "Basic "*bytestring(encode(Base64, uri.userinfo))
    end
    host = uri.port == 0 ? uri.host : "$(uri.host):$(uri.port)"
    request = default_request(method,resource,host,data,headers)
    request.uri = uri
    return request
end

### Response Parsing

immutable ResponseParser
    parser::Parser
    settings::ParserSettings

    function ResponseParser(r)
        parser = Parser()
        parser.data = r
        http_parser_init(parser,false)
        settings = ParserSettings(on_message_begin_cb, on_url_cb,
                          on_status_complete_cb, on_header_field_cb,
                          on_header_value_cb, on_headers_complete_cb,
                          on_body_cb, on_message_complete_cb)

        new(parser, settings)
    end
end

pd(p::Ptr{Parser}) = (unsafe_load(p).data)::ResponseStream

# All the `HttpParser` callbacks to be run in C land
# Each one adds data to the `Request` until it is complete
#
function on_message_begin(parser)
    #unsafe_ref(parser).data = Response()
    pd(parser).state = OnMessageBegin
    return 0
end

function on_url(parser, at, len)
    r = pd(parser).response
    r.resource = string(r.resource, bytestring(convert(Ptr{Uint8}, at), Int(len)))
    return 0
end

function on_status_complete(parser)
    pd(parser).response.status = (unsafe_load(parser)).status_code
    return 0
end

# Gather the header_field, set the field
# on header value, set the value for the current field
# there might be a better way to do
# this: https://github.com/joyent/node/blob/master/src/node_http_parser.cc#L207

function on_header_field(parser, at, len)
    r = pd(parser).response
    header = bytestring(convert(Ptr{Uint8}, at))
    header_field = header[1:len]
    r.headers["current_header"] = header_field
    return 0
end

function parse_set_cookie(value)
    parts = split(value, ';')
    isempty(parts) && return Nullable{Cookie}()
    nameval = split(parts[1], '=', limit=2)
    length(nameval)==2 || return Nullable{Cookie}()
    name, value = nameval
    c = Cookie(strip(name), strip(value))
    for part in parts[2:end]
        nameval = split(part, '=', limit=2)
        if length(nameval)==2
            name, value = nameval
            c.attrs[strip(name)] = strip(value)
        else
            c.attrs[strip(nameval[1])] = utf8("")
        end
    end
    return Nullable(c)
end

const is_set_cookie = r"set-cookie"i

function on_header_value(parser, at, len)
    r = pd(parser).response
    s = bytestring(convert(Ptr{Uint8}, at), Int(len))
    current_header = r.headers["current_header"]
    if is_set_cookie(current_header)
        maybe_cookie = parse_set_cookie(s)
        if !isnull(maybe_cookie)
            cookie = get(maybe_cookie)
            r.cookies[cookie.name] = cookie
        end
    else
        r.headers[current_header] = s
    end
    r.headers["current_header"] = ""
    return 0
end

function on_headers_complete(parser)
    r = pd(parser).response
    p = unsafe_load(parser)
    # get first two bits of p.type_and_flags
    ptype = p.type_and_flags & 0x03
    if ptype == 0
        r.method = http_method_str(convert(Int, p.method))
    elseif ptype == 1
        r.headers["status_code"] = string(convert(Int, p.status_code))
    end
    r.headers["http_major"] = string(convert(Int, p.http_major))
    r.headers["http_minor"] = string(convert(Int, p.http_minor))
    r.headers["Keep-Alive"] = string(http_should_keep_alive(parser))
    pop!(r.headers, "current_header", nothing)
    pd(parser).state = HeadersDone
    return 0
end

function on_body(parser, at, len)
    response_stream = pd(parser)
    append!(response_stream.buffer.data, pointer_to_array(convert(Ptr{UInt8}, at), (len,)))
    response_stream.buffer.size = length(response_stream.buffer.data)
    return 0
end

function on_message_complete(parser)
    response_stream = pd(parser)
    response_stream.state = BodyDone
    return 0
end

immutable TimeoutException <: Exception
    timeout::Float64
end

function Base.show(io::IO, err::TimeoutException)
    print(io, "TimeoutException: server did not respond for more than $(err.timeout) seconds. ")
end

function process_response(stream, timeout, target_state, num_bytes=0)
    # rp = ResponseParser(stream)
    rp = stream.parser
    last_received = now()
    status_channel = Channel{Symbol}(1)
    if timeout < Inf
        Timer(0, timeout) do timer
            delta = now() - last_received
            if timeout_in_sec(delta) > timeout
                close(timer)
                put!(status_channel, :timeout)
            end
        end
    end
    @async begin
        bytes_received = 0
        while stream.state≠target_state && !eof(stream)
            if num_bytes > 0 && bytes_received ≥ num_bytes
                break
            end
            last_received = now()
            data = readavailable(stream.socket)
            if length(data) > 0
                add_data(rp, data)
                bytes_received += length(data)
            end
        end
        put!(status_channel, :success)
    end
    status = take!(status_channel)
    status == :timeout && throw(TimeoutException(timeout))
    # close(stream)
    # if in(get(r.headers,"Content-Encoding",""), ("gzip","deflate"))
    #     r.data = decompress(r.data)
    # end
    # r
    stream
end

# Passes `request_data` into `parser`
function add_data(parser::ResponseParser, request_data)
    http_parser_execute(parser.parser, parser.settings, request_data)
end

# open_stream(uri::URI, headers, data, method) = open_stream(uri,default_request(uri,headers,data,method))

scheme(uri::URI) = isdefined(uri, :scheme) ? uri.scheme : uri.schema

function tls_dbg(level, filename, number, msg)
    warn("MbedTLS emitted debug info: $msg in $filename:$number")
end

function get_default_tls_config(verify=true)
    conf = MbedTLS.SSLConfig()
    MbedTLS.config_defaults!(conf)

    entropy = MbedTLS.Entropy()
    rng = MbedTLS.CtrDrbg()
    MbedTLS.seed!(rng, entropy)
    MbedTLS.rng!(conf, rng)

    MbedTLS.authmode!(conf,
      verify ? MbedTLS.MBEDTLS_SSL_VERIFY_REQUIRED : MbedTLS.MBEDTLS_SSL_VERIFY_NONE)
    MbedTLS.dbg!(conf, tls_dbg)
    MbedTLS.ca_chain!(conf)

    conf
end

@enum ResponseState NotStarted OnMessageBegin HeadersDone OnBody BodyDone

type ResponseStream{T<:IO} <: Base.AsyncStream
    response::Response
    socket::T
    state::ResponseState
    buffer::IOBuffer
    parser::ResponseParser

    ResponseStream() = new()
end

function ResponseStream{T}(response, socket::T)
    r = ResponseStream{T}()
    r.response = response
    r.socket = socket
    r.state = NotStarted
    r.buffer = IOBuffer()
    r.parser = ResponseParser(r)
    r
end

function Base.eof(stream::ResponseStream)
    eof(stream.socket) || (stream.state==BodyDone && eof(stream.buffer))
end
#Base.write(stream::ResponseStream, data::Vector{UInt8}) = write(stream.socket, data)
function Base.readbytes!(stream::ResponseStream, data::Vector{UInt8}, sz)
    while nb_available(stream.buffer) < sz && !eof(stream.socket) && stream.state≠BodyDone
        process_response(stream, Inf, BodyDone, 2sz)
    end
    sz_buf = readbytes!(stream.buffer, data, sz)
    sz_buf
end

function Base.readbytes(stream::ResponseStream, sz)
    buf = Vector{UInt8}(sz)
    readbytes!(stream, buf, sz)
    buf
end

function Base.readall(stream::ResponseStream)
    process_response(stream, Inf, BodyDone)
    readall(stream.buffer)
end

Base.close(stream::ResponseStream) = stream.isopen=false
Base.nb_available(stream::ResponseStream) = nb_available(stream.socket) + nb_available(stream.buffer)

for getter in [:headers, :cookies, :statuscode, :requestfor, :requestsfor]
    @eval $getter(stream::ResponseStream) = $getter(stream.response)
end

function open_stream(uri::URI,req::Request,tls_conf)
    if scheme(uri) != "http" && scheme(uri) != "https"
        error("Unsupported scheme \"$(scheme(uri))\"")
    end
    ip = Base.getaddrinfo(uri.host)
    if scheme(uri) == "http"
        stream = Base.connect(ip, uri.port == 0 ? 80 : uri.port)
    else
        # Initialize HTTPS
        sock = Base.connect(ip, uri.port == 0 ? 443 : uri.port)
        stream = MbedTLS.SSLContext()
        MbedTLS.setup!(stream, tls_conf)
        MbedTLS.set_bio!(stream, sock)
        MbedTLS.handshake(stream)
    end
    # render(stream, req)
    resp = Response()
    push!(resp.requests, req)
    ResponseStream(resp, stream)
end

function format_query_str(queryparams; uri = URI(""))
    query_str = isempty(uri.query) ? string() : string(uri.query, "&")

    for (k, v) in queryparams
        query_str *= "$(URIParser.escape(string(k)))=$(URIParser.escape(string(v)))&"
    end
    chop(query_str) # remove the trailing &
end

#
# Chunked Data Transfer
#

immutable ChunkedStream
    io::IO
end
function write(io::ChunkedStream,arg)
    write(io.io,string(hex(sizeof(arg)),CRLF))
    write(io.io,arg)
    write(io.io,string(CRLF))
end

#
# File uploads
#
# Upload a file using multipart form upload. `file` may be one of:
#
#   - An IO object whose contents will be uploaded
#   - A string or Array to be sent
#
# Note that when passing an IO object, the IO object may not otherwise be modified
# until the request completes. Optionally you may set `close` to true to have Requests
# automatically close your file when it's done with it.
#

immutable FileParam
    file::Union(IO,Base.File,String,Vector{Uint8})     # The file
    # The content type (default: "", which is interpreted as text/plain serverside)
    ContentType::ASCIIString
    name::ASCIIString                                  # The fieldname (in a form)
    filename::ASCIIString                              # The filename (of the actual file)
    # Whether or not to close the file when the request is done
    close::Bool

    function FileParam(str::Union(String,Vector{Uint8}),ContentType="",name="",filename="")
        new(str,ContentType,name,filename,false)
    end

    function FileParam(io::IO,ContentType="",name="",filename="",close::Bool=false)
        new(io,ContentType,name,filename,close)
    end

    function FileParam(io::Base.File,ContentType="",name="",filename="",close::Bool=false)
        if !isopen(io)
            close = true
        end
        new(io,ContentType,name,filename,close)
    end
end

# Determine whether or not we need to use
datasize(::IO) = -1
datasize(f::Union(String,Array{Uint8})) = sizeof(f)
datasize(f::File) = filesize(f)
datasize(f::IOBuffer) = nb_available(f)
function datasize(io::IOStream)
    iofd = fd(io)
    # If this IOStream is not backed by a file, we can't find the filesize
    if iofd == -1
        return -1
    else
        return filesize(iofd) - position(io)
    end
end

const multipart_mime = "multipart/form-data; boundary="
const part_mime = "Content-Disposition: form-data"
const name_file = "; name=\""
const filename_file = "; filename=\""
const ContentType_header = "Content-Type: "

function write_part_header(stream,file::FileParam,boundary)
    buf = IOBuffer()
    write(buf,"--",boundary,CRLF)
    write(buf,part_mime)
    !isempty(file.name) && write(buf,name_file,file.name,'\"')
    !isempty(file.filename) && write(buf,filename_file,file.filename,'\"')
    write(buf,CRLF)
    !isempty(file.ContentType) && write(buf,ContentType_header,file.ContentType,CRLF)
    write(buf,CRLF)
    write(stream,takebuf_array(buf))
end

# Write a file by reading it in 1MB chunks (unless we know its size and it's smaller than that)
function write_file(stream,file::IO,datasize,doclose)
    datasize == datasize == -1 : 2^20 : min(2^20,datasize)
    x = Array(Uint8,datasize)
    while !eof(file)
        nread = readbytes!(file,x)
        if nread == 2^20
            write(stream,x)
        else
            write(stream,sub(x,1:nread))
        end
    end
    doclose && close(file)
end

# Write a file by mmaping it
function write_file(stream,file::IOStream,datasize,doclose)
    @assert datasize != -1
    write(stream, Mmap.mmap(file, Vector{UInt8}, datasize, position(file)))
    doclose && close(file)
end

# Write data already in memory
function write_file(stream,file::Union(String,Array{Uint8}),datasize,doclose)
    @assert datasize != -1
    write(stream,file)
    doclose && close(file)
end

function write_file(stream,file::IOBuffer,datasize,doclose)
    @assert datasize != -1
    write(stream,sub(file.data,(position(file)+1):(position(file)+nb_available(file))))
    doclose && close(file)
end

function partheadersize(file,datasize,boundary)
    totalsize = 0
    # Chucksize =
    #   +  "--" (2) + boundary (sizeof(boundary)) + "\r\n" (2)
    totalsize += (2 + sizeof(boundary) ) + 2
    #   + multipart_mime + optional names + "\r\n"(2)
    totalsize += sizeof(multipart_mime)
    if !isempty(file.name)
        # +1 for "\""
        totalsize += sizeof(name_file) + sizeof(file.name) + 1
    end
    if !isempty(file.filename)
        # +1 for "\""
        totalsize += sizeof(filename_file) + sizeof(file.filename) + 1
    end
    totalsize += 2
    if !isempty(file.ContentType)
        # +2 for "\r\n"
        totalsize += sizeof(ContentType_header) + sizeof(file.ContentType) + 2
    end
    # "\r\n" + The actual data + "\r\n" (2)
    totalsize += 2 + datasize + 2
    totalsize
end

choose_boundary() = hex(rand(Uint128))

function do_multipart_send(stream, files, datasizes, boundary, chunked)
    if chunked
        begin
            for i = 1:length(files)
                file = files[i]
                if datasizes[i] != -1
                    # Make this all one chunk
                    #write(stream,hex(datasizes[i]+partheadersize(file,0,boundary)),CRLF)
                    write_part_header(ChunkedStream(stream),file, boundary)
                    write_file(ChunkedStream(stream),file.file,datasizes[i],file.close)
                    # File CRLF
                    write(ChunkedStream(stream),CRLF)
                    # Chunk CRLF
                    #write(stream,CRLF)
                else
                    phs = partheadersize(file,0,boundary)-2
                    # Make the part header one chunk
                    write(stream,hex(phs),CRLF)
                    write_part_header(stream,file, boundary)
                    # Chunk CRLF
                    write(stream,CRLF)
                    # Write the rest as a chunk
                    write_file(ChunkedStream(stream),file.file,datasizes[i],file.close)
                    # This sucks, I'm making and extra chunk just for CRLF, but
                    # so be it for now
                    write(stream,"1\r\n\r\n\r\n")
                end
            end
            write(ChunkedStream(stream),"--$boundary--")
            write(stream,string(hex(0),CRLF,CRLF))
        end
    else
        begin
            for i = 1:length(files)
                file = files[i]
                write_part_header(stream,file, boundary)
                write_file(stream,file.file,datasizes[i],file.close)
                write(stream,CRLF)
            end
            write(stream, "--$boundary--", CRLF)
        end
    end

end

function prepare_multipart_send(uri, headers, files, verb)
    local boundary

    if !haskey(headers,"Content-Type")
        boundary = choose_boundary()
        headers["Content-Type"] = multipart_mime*boundary
    else

        if headers["Content-Type"][1:sizeof(multipart_mime)] != multipart_mime
            error("Cannot extract boundary from MIME type")
        end
        boundary = headers["Content-Type"][(sizeof(multipart_mime)+1):end]
    end

    chunked = false
    if haskey(headers,"Transfer-Encoding")
        if headers["Transfer-Encoding"] != "chunked"
            error("Unrecognized Transfer-Encoding")
        end
        chunked = true
    end

    datasizes = Array(Int,length(files))

    # Try to determine final size of the request. If this fails,
    # we fall back to chunked transfer
    totalsize = 0
    for i = 1:length(files)
        file = files[i]
        size = datasizes[i] = datasize(file.file)
        if size == -1
            if !chunked
                error("""Tried to pass in an IO object that is not of fixed size.\n
                         This is only support with the chunked Transfer-Encoding.\n
                         Please verify however that the server you are connecting to\n
                         supports chunked transfer encoding as support for this feature\n
                         is broken in a large number of servers.\n""")
            end
            # don't break because we'll still use the datasize later if
            # available to optimize chunked transfer
        end
        totalsize += partheadersize(file,size,boundary)
    end
    # "--" (2) + boundary (sizeof(boundary)) + "--" (2) + CRLF (2)
    totalsize += 2 + sizeof(boundary) + 2 + 2

    req = default_request(uri,headers,"",verb)

    if chunked
        req.headers["Transfer-Encoding"] = "chunked"
    else
        req.headers["Content-Length"] = dec(totalsize)
    end

    req, datasizes, boundary, chunked
end

function send_multipart(uri, headers, files, verb, timeout, tls_conf)
    req, datasizes, boundary, chunked = prepare_multipart_send(uri,headers,files,verb)
    stream = open_stream(uri,req,tls_conf)
    do_multipart_send(stream,files,datasizes, boundary, chunked)
    process_response(stream, timeout), req
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
    cookie_request_header([cookie.name => cookie.value for cookie in cookies])

const is_location = r"^location$"i

function get_redirect_uri(response)
    300 <= statuscode(response) < 400 || return Nullable{URI}()
    hdrs = headers(response)
    for (key, val) in hdrs
        if is_location(key)
            uri = URI(val)
            if isempty(uri.host)  # Redirect URL was given as a relative path
                request = requestfor(response)
                uri = URI(request.uri.host, uri.path)
            end
            return Nullable(uri)
        end
    end
    return Nullable{URI}()
end

const MAX_REDIRECTS = 5

immutable RedirectException <: Exception
    max_redirects::Int
end

function Base.show(io::IO, err::RedirectException)
    print(io, "RedirectException: more than $(err.max_redirects) redirects attempted.")
end

macro check_body()
  has_body = esc(:has_body)
  quote
    $has_body && error("Multiple body options specified. Please only specify one")
    $has_body = true
  end
end

function do_request(uri::URI, verb; kwargs...)
    response_stream = do_stream_request(uri, verb; kwargs...)
    process_response(response_stream, Inf, BodyDone)
    response = response_stream.response
    response.data = takebuf_array(response_stream.buffer)
    response
end

# function default_request_args(overrides)
#     d = Dict()
#     d[:headers] = Dict{String, String}()
#     d[:cookies] = nothing
#     d[:data] = nothing
#     d[:json] = nothing
#     d[:files] = FileParam[]
#     d[:timeout] = nothing
#     d[:query] = Dict()
#     d[:allow_redirects] = true
#     d[:max_redirects] = MAX_REDIRECTS
#     d[:request_history] = Request[]
#     d[:tls_conf] = TLS_VERIFY
#     merge!(d, overrides)
#     d
# end

function do_stream_request(uri::URI, verb; headers = Dict{String, String}(),
                        cookies = nothing,
                        data = nothing,
                        json = nothing,
                        files = FileParam[],
                        timeout = nothing,
                        query::Dict = Dict(),
                        allow_redirects = true,
                        max_redirects = MAX_REDIRECTS,
                        request_history = Request[],
                        tls_conf = TLS_VERIFY
                        )

    query_str = format_query_str(query; uri = uri)
    newuri = URI(uri; query = query_str)
    timeout_sec = timeout_in_sec(timeout)

    body = ""
    has_body = false
    if json !== nothing
        @check_body
        if get(headers,"Content-Type","application/json") != "application/json"
            error("Tried to send json data with incompatible Content-Type")
        end
        headers["Content-Type"] = "application/json"
        body = JSON.json(json)
    end

    if data !== nothing
        @check_body
        body = data
    end

    if cookies != nothing
        headers["Cookie"] = cookie_request_header(cookies)
    end

    if !isempty(files)
        @check_body
        verb == "POST" || error("Multipart file post only supported with POST")
        if haskey(headers,"Content-Type") && !beginswith(headers["Content-Type"],"multipart/form-data")
            error("""Tried to send form data with invalid Content-Type. """)
        end
        response, request = send_multipart(newuri, headers, files, verb, timeout_sec, tls_conf)
        push!(request_history, request)
        response.requests = request_history
    else
        request = default_request(newuri, headers, body, verb)
        push!(request_history, request)
        response_stream = open_stream(newuri, request, tls_conf)
        send_request(response_stream)
        process_response(response_stream, timeout_sec, HeadersDone)
        response_stream.response.requests = request_history
        # response.requests = request_history
    end
    if allow_redirects && verb ≠ :head
        redirect_uri = get_redirect_uri(response_stream)
        if !isnull(redirect_uri)
            length(response.requests) > max_redirects &&
                throw(RedirectException(max_redirects))
            return do_request(get(redirect_uri), verb; headers=headers,
                 data=data, json=json, files=files, timeout=timeout,
                 allow_redirects=allow_redirects, max_redirects=max_redirects,
                 request_history=request_history, tls_conf=tls_conf)
        end
    end
    return response_stream
end

for f in [:get, :post, :put, :delete, :head,
          :trace, :options, :patch, :connect]
    f_str = uppercase(string(f))
    f_stream = symbol(string(f, "_streaming"))
    @eval begin
        function ($f)(uri::URI, data::String; headers::Dict=Dict())
            do_request(uri, $f_str; data=data, headers=headers)
        end
        function ($f_stream)(uri::URI, data::String; headers::Dict=Dict(0))
            do_stream_request(uri, $f_str; data=data, headers=headers)
        end

        ($f)(uri::String; args...) = ($f)(URI(uri); args...)
        ($f)(uri::URI; args...) = do_request(uri, $f_str; args...)

        ($f_stream)(uri::String; args...) = ($f_stream)(URI(uri); args...)
        ($f_stream)(uri::URI; args...) = do_stream_request(uri, $f_str; args...)
    end
end

#include("precompile.jl")

end
