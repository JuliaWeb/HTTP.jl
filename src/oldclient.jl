function make_input_stream(ctx)
    headers = ctx.request.headers
    input_stream = C_NULL
    if ctx.request.body !== nothing
        if ctx.request.body isa AbstractString
            if ctx.request.body isa String
                ctx.request_body = unsafe_wrap(Vector{UInt8}, ctx.request.body)
            else
                ctx.request_body = Vector{UInt8}(ctx.request.body)
            end
            ctx.body_byte_cursor = aws_byte_cursor_from_c_str(ctx.request.body)
            input_stream = aws_input_stream_new_from_cursor(ctx.client.settings.allocator, FieldRef(ctx, :body_byte_cursor))
        elseif ctx.request.body isa AbstractVector{UInt8}
            ctx.request_body = ctx.request.body
            rb = ctx.request_body
            GC.@preserve rb begin
                ctx.body_byte_cursor = aws_byte_cursor(sizeof(rb), pointer(rb))
                input_stream = aws_input_stream_new_from_cursor(ctx.client.settings.allocator, FieldRef(ctx, :body_byte_cursor))
            end
        elseif ctx.request.body isa Union{AbstractDict, NamedTuple}
            # add application/x-www-form-urlencoded content-type header if not already present
            if !hasheader(headers, "content-type")
                setheader(headers, "content-type", "application/x-www-form-urlencoded")
            end
            # hold a reference to the request body in order to gc-preserve it
            ctx.request_body = URIs.escapeuri(ctx.request.body)
            ctx.body_byte_cursor = aws_byte_cursor_from_c_str(ctx.request_body)
            input_stream = aws_input_stream_new_from_cursor(ctx.client.settings.allocator, FieldRef(ctx, :body_byte_cursor))
        elseif ctx.request.body isa IOStream
            ctx.request_body = Mmap.mmap(ctx.request.body)
            input_stream = aws_input_stream_new_from_open_file(ctx.client.settings.allocator, Libc.FILE(ctx.request.body))
        elseif ctx.request.body isa Form
            # add multipart content-type header if not already present
            if !hasheader(headers, "content-type")
                setheader(headers, "content-type", content_type(ctx.request.body))
            end
            # we set the request.body to the Form bytes in order to gc-preserve them
            ctx.request_body = read(ctx.request.body)
            rb = ctx.request_body
            GC.@preserve rb begin
                ctx.body_byte_cursor = aws_byte_cursor(sizeof(rb), pointer(rb))
                input_stream = aws_input_stream_new_from_cursor(ctx.client.settings.allocator, FieldRef(ctx, :body_byte_cursor))
            end
        elseif ctx.request.body isa IO
            # we set the request.body to the IO bytes in order to gc-preserve them
            bytes = readavailable(ctx.request.body)
            while !eof(ctx.request.body)
                append!(bytes, readavailable(ctx.request.body))
            end
            ctx.request_body = bytes
            rb = ctx.request_body
            GC.@preserve rb begin
                ctx.body_byte_cursor = aws_byte_cursor(sizeof(rb), pointer(rb))
                input_stream = aws_input_stream_new_from_cursor(ctx.client.settings.allocator, FieldRef(ctx, :body_byte_cursor))
            end
        else
            throw(ArgumentError("request body must be a string, vector of UInt8, or IO"))
        end
        data_len_ref = Ref(0)
        aws_input_stream_get_length(input_stream, data_len_ref) != 0 && aws_throw_error()
        data_len = data_len_ref[]
        ctx.response.metrics.request_body_length = data_len
        if data_len > 0
            setheader(headers, "content-length", string(data_len))
        else
            aws_input_stream_destroy(input_stream)
            input_stream = C_NULL
        end
    end
    return input_stream
end

const on_setup = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_setup(conn, error_code, ctx_ptr)
    ctx = unsafe_pointer_to_objref(ctx_ptr)
    # println("on setup")
    if error_code != 0
        ctx.error = CapturedException(aws_error(error_code), Base.backtrace())
        if error_code == AWS_IO_DNS_INVALID_NAME || error_code == AWS_IO_TLS_ERROR_NEGOTIATION_FAILURE
            ctx.should_retry = false
        else
            ctx.should_retry = true
        end
        Threads.notify(ctx.completed)
        return
    end
    # build request
    ctx.verbose >= 1 && @info "building request: $(ctx.request.uri.host)"
    ctx.connection = conn
    protocol_version = aws_http_connection_get_version(conn)
    ctx.response.version = protocol_version == AWS_HTTP_VERSION_2 ? "2" : protocol_version == AWS_HTTP_VERSION_1_1 ? "1.1" : "1.0"
    ctx.request.version = ctx.response.version
    # build up request headers
    headers = Headers()
    path = resource(ctx.request.uri)
    if protocol_version == AWS_HTTP_VERSION_2
        # set scheme
        setheader(headers, ":scheme", ctx.request.uri.scheme)
        # set authority
        setheader(headers, ":authority", ctx.request.uri.host)
    else
        setheader(headers, "host", ctx.request.uri.host)
    end
    
    # accept header
    if !hasheader(headers, "accept")
        setheader(headers, "accept", "*/*")
    end
    # user-agent header
    if !hasheader(headers, "user-agent")
        setheader(headers, "user-agent", USER_AGENT[])
    end
    # accept-encoding
    if ctx.decompress === nothing || ctx.decompress
        setheader(headers, "accept-encoding", "gzip")
    end
    # basic auth if present
    if !isempty(ctx.request.uri.userinfo)
        setheader(headers, "authorization", "Basic $(base64encode(ctx.request.uri.userinfo))")
    end
    # add any user-provided headers
    for header in ctx.request.headers
        push!(headers, lowercase(string(header[1])) => string(header[2]))
    end
    ctx.request.headers = headers
    # process request body if present
    input_stream = make_input_stream(ctx)
    # call a user-provided modifier function (if provided)
    if ctx.modifier !== nothing
        body_modified = ctx.modifier(ctx.request, ctx.request_body)
        if body_modified === true
            if input_stream != C_NULL
                # destroy previous input_stream
                aws_input_stream_destroy(input_stream)
            end
            input_stream = make_input_stream(ctx)
        end
    end

    # prepare C version of request
    request = protocol_version == AWS_HTTP_VERSION_2 ?
          aws_http2_message_new_request(ctx.client.settings.allocator) :
          aws_http_message_new_request(ctx.client.settings.allocator)
    if request == C_NULL
        ctx.error = CapturedException(aws_error(), Base.backtrace())
        ctx.should_retry = true
        Threads.notify(ctx.completed)
        return
    end
    # set method
    aws_http_message_set_request_method(request, aws_byte_cursor_from_c_str(ctx.request.method))
    # set path
    aws_http_message_set_request_path(request, aws_byte_cursor_from_c_str(path))
    # add headers to request
    for (k, v) in headers
        header = aws_http_header(aws_byte_cursor_from_c_str(k), aws_byte_cursor_from_c_str(v), AWS_HTTP_HEADER_COMPRESSION_USE_CACHE)
        aws_http_message_add_header(request, header)
    end
    # set body from input_stream if present
    if input_stream != C_NULL
        aws_http_message_set_body_stream(request, input_stream)
    end
    ctx.request_options = Ref(aws_http_make_request_options(
        1,
        request,
        ctx_ptr,
        on_response_headers[],
        on_response_header_block_done[],
        on_response_body[],
        on_metrics[],
        on_complete[],
        on_destroy[],
        false,
        ctx.readtimeout # response_first_byte_timeout_ms
    ))
    stream = aws_http_connection_make_request(conn, ctx.request_options)
    if stream == C_NULL
        ctx.error = CapturedException(aws_error(), Base.backtrace())
        ctx.should_retry = true
        Threads.notify(ctx.completed)
        return
    end
    aws_http_message_release(request)
    ctx.stream = stream
    # this schedules our request to be written over the wire
    # our various on_response_X callbacks will be called as the response is received
    ctx.verbose >= 3 && print_request(stdout, ctx.request.method, ctx.request.version, String(path), headers, @something(ctx.request.body, UInt8[]))
    ctx.verbose >= 1 && @info "activating stream: $(ctx.request.uri.host)"
    aws_http_stream_activate(stream)
    return
end

const on_shutdown = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_shutdown(conn, error_code, ctx_ptr)
    ctx = unsafe_pointer_to_objref(ctx_ptr)
    # println("on setup")
    if error_code != 0
        ctx.error = CapturedException(aws_error(error_code), Base.backtrace())
        if error_code == AWS_IO_DNS_INVALID_NAME || error_code == AWS_IO_TLS_ERROR_NEGOTIATION_FAILURE
            ctx.should_retry = false
        else
            ctx.should_retry = true
        end
    end
    return
end

const on_response_headers = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_response_headers(stream, header_block, header_array::Ptr{aws_http_header}, num_headers, ctx_ptr)
    ctx = unsafe_pointer_to_objref(ctx_ptr)
    headers = ctx.response.headers
    oldlen = length(headers)
    newlen = oldlen + Int(num_headers)
    newheaders = Vector{Header}(undef, newlen)
    ctx.response.headers = newheaders
    for i = 1:oldlen
        newheaders[i] = headers[i]
    end
    for i = 1:num_headers
        header = unsafe_load(header_array, i)
        name = unsafe_string(header.name.ptr, header.name.len)
        value = unsafe_string(header.value.ptr, header.value.len)
        newheaders[oldlen + i] = name => value
    end
    return Cint(0)
end

writebuf(body, maxsize=length(body) == 0 ? typemax(Int64) : length(body)) = Base.GenericIOBuffer{AbstractVector{UInt8}}(body, true, true, true, false, maxsize)

const on_response_header_block_done = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_response_header_block_done(stream, header_block, ctx_ptr)
    ctx = unsafe_pointer_to_objref(ctx_ptr)
    ref = Ref{Cint}()
    aws_http_stream_get_incoming_response_status(stream, ref)
    ctx.response.status = ref[]
    if ctx.status_exception && ctx.response.status >= 299
        ctx.error = StatusError(ctx.request, ctx.response)
        ctx.should_retry = ctx.response.status in (301, 302, 303, 307, 308, 408, 429, 500, 502, 503, 504, 599) && (ctx.request.method != "POST" || ctx.retry_non_idempotent)
    end
    # prepare our response body to be written to
    # ctx.response.body is either `nothing`, an `AbstractVector{UInt8}`, or an IO
    # we try to use content-length, if present, to presize our buffers, but chunked
    # responses won't have content-length, so still have to account for that
    len = parse(Int, getheader(ctx.response.headers, "content-length", "0"))
    response_body = if ctx.error !== nothing && ctx.should_retry
        # if it's an error and we might retry, we write the body unconditionally to
        # our own fresh vector (and will commit it to a user-provided body later if needed)
        Vector{UInt8}(undef, len)
    elseif ctx.response.body === nothing
        # no response body provided, so let's allocate one for the user
        Vector{UInt8}(undef, len)
    elseif ctx.response.body isa AbstractVector{UInt8}
        ctx.response.body
    else
        ctx.response.body
    end
    ctx.temp_response_body = if ctx.decompress === true || (ctx.decompress === nothing && getheader(ctx.response.headers, "content-encoding") == "gzip")
        # we're going to gzip decompress the response body
        ctx.gzip_decompressing = true
        CodecZlib.GzipDecompressorStream(response_body isa AbstractVector{UInt8} ? writebuf(response_body, typemax(Int64)) : response_body)
    elseif response_body isa AbstractVector{UInt8}
        writebuf(response_body)
    else
        # we're going to write the response body directly to the user-provided IO
        response_body
    end
    # if we might retry, we store the error response body in a temporary buffer
    if ctx.error !== nothing
        ctx.error_response_body = response_body
    else
        ctx.response.body = response_body
    end
    ctx.verbose >= 1 && @info "response headers received: $(ctx.request.uri.host)"
    return Cint(0)
end

const on_response_body = Ref{Ptr{Cvoid}}(C_NULL)

function hasroom(buf::Base.GenericIOBuffer, n)
    requested_buffer_capacity = (buf.append ? buf.size : (buf.ptr - 1)) + n
    return (requested_buffer_capacity <= length(buf.data)) || (buf.writable && requested_buffer_capacity <= buf.maxsize)
end

function c_on_response_body(stream, data::Ptr{aws_byte_cursor}, ctx_ptr)
    ctx = unsafe_pointer_to_objref(ctx_ptr)
    bc = unsafe_load(data)
    body = ctx.temp_response_body
    ctx.response.metrics.response_body_length += bc.len
    # common response body manual type unrolling here
    if body isa IOBuffer
        if !hasroom(body, bc.len)
            @error "response body buffer is too small 1"
            ctx.error = CapturedException(ArgumentError("response body buffer is too small"), Base.backtrace())
            ctx.should_retry = false
            return Cint(0)
        end
        unsafe_write(body, bc.ptr, bc.len)
    elseif body isa Base.GenericIOBuffer{SubArray{UInt8, 1, Vector{UInt8}, Tuple{UnitRange{Int64}}, true}}
        if !hasroom(body, bc.len)
            @error "response body buffer is too small 2"
            ctx.error = CapturedException(ArgumentError("response body buffer is too small"), Base.backtrace())
            ctx.should_retry = false
            return Cint(0)
        end
        unsafe_write(body, bc.ptr, bc.len)
    elseif body isa CodecZlib.TranscodingStreams.TranscodingStream{GzipDecompressor, IOBuffer}
        unsafe_write(body, bc.ptr, bc.len)
    else
        unsafe_write(body, bc.ptr, bc.len)
    end
    ctx.verbose >= 1 && @info "response body received: $(ctx.request.uri.host)"
    return Cint(0)
end

const on_metrics = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_metrics(stream, metrics::Ptr{aws_http_stream_metrics}, ctx_ptr)
    ctx = unsafe_pointer_to_objref(ctx_ptr)
    # println("on metrics")
    m = unsafe_load(metrics)
    if m.send_start_timestamp_ns != -1
        ctx.response.metrics.stream_metrics = m
    end
    return
end

const on_complete = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_complete(stream, error_code, ctx_ptr)
    ctx = unsafe_pointer_to_objref(ctx_ptr)
    if error_code != 0
        ctx.error = CapturedException(aws_error(error_code), Base.backtrace())
        if error_code == AWS_IO_DNS_INVALID_NAME || error_code == AWS_IO_TLS_ERROR_NEGOTIATION_FAILURE
            ctx.should_retry = false
        else
            ctx.should_retry = true
        end
    end
    if ctx.gzip_decompressing
        close(ctx.temp_response_body)
    end
    aws_http_stream_release(stream)
    # release connection back to connection manager
    aws_http_connection_manager_release_connection(ctx.client.connection_manager, ctx.connection)
    ctx.verbose >= 3 && print_response(stdout, ctx.response.status, ctx.response.version, ctx.response.headers, @something(ctx.error_response_body, ctx.response.body, UInt8[]))
    ctx.stream = C_NULL
    Threads.notify(ctx.completed)
    return
end

const on_destroy = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_destroy(ctx)
    return
end

mkheaders(h::Headers) = h
function mkheaders(h, headers=Vector{Header}(undef, length(h)))::Headers
    # validation
    for (i, head) in enumerate(h)
        head isa String && throw(ArgumentError("header must be passed as key => value pair: `$head`"))
        length(head) != 2 && throw(ArgumentError("invalid header key-value pair: $head"))
        headers[i] = SubString(string(head[1])) => SubString(string(head[2]))
    end
    return headers
end

request(method, url, h=Header[], b::RequestBodyTypes=nothing; allocator=default_aws_allocator(), headers=h, body::RequestBodyTypes=b, query=nothing, kw...) =
    request(Request(method, url, mkheaders(headers), body, allocator, query); kw...)

# main entrypoint for making an HTTP request
# can provide method, url, headers, body, along with various keyword arguments
function request(req::Request;
    client::Union{Nothing, Client}=nothing,
    # redirect options
    redirect=true,
    redirect_limit=3,
    redirect_method=nothing,
    forwardheaders=true,
    # response options
    response_stream=nothing, # compat
    response_body=response_stream,
    decompress::Union{Nothing, Bool}=nothing,
    status_exception::Bool=true,
    readtimeout::Int=0, # only supported for HTTP 1.1, not HTTP 2 (current aws limitation)
    retry_non_idempotent::Bool=false,
    modifier=nothing,
    verbose=0,
    # only client keywords in catch-all
    kw...
    # NOTE: new keywords must also be added to the @client macro definition below
)
    verbose >= 1 && @info "getting client: $(req.uri.scheme), $(req.uri.host), $(getport(req._uri))"
    client = @something(client, getclient(ClientSettings(req.uri.scheme, req.uri.host, getport(req._uri); kw...)))::Client
    # create a request context for shared state that we pass between all the callbacks
    ctx = RequestContext(client, req, Response(response_body), decompress, status_exception, retry_non_idempotent, modifier, readtimeout, verbose)
    return GC.@preserve ctx _request(ctx, req, client, redirect, redirect_limit, redirect_method, forwardheaders, verbose)
end

function _request(ctx, req, client, redirect, redirect_limit, redirect_method, forwardheaders, verbose)
    # NOTE: this is threadsafe based on our usage of the "standard retry strategy" default aws implementation
@label acquire_retry_token
    verbose >= 1 && @info "acquiring retry token: $(req.uri.host)"
    host_ref = Ref(req._uri.host_name)
    if aws_retry_strategy_acquire_retry_token(client.retry_strategy, host_ref, on_acquired[], pointer_from_objref(ctx), client.settings.retry_timeout_ms) != 0
        ctx.error = CapturedException(aws_error(), Base.backtrace())
        @goto error_fail
    end
    error_type = AWS_RETRY_ERROR_TYPE_TRANSIENT

    # eventually, one of our callbacks will notify ctx.completed, at which point we can return
@label request_wait
    wait(ctx.completed)
    if ctx.stream != C_NULL
        @warn "stream not closed" stream_id=aws_http_stream_get_id(ctx.stream)
    end
    # check for redirect
    verbose >= 2 && @info "checking for redirect / retry" error=ctx.error should_retry=ctx.should_retry redirect_limit status=ctx.response.status location=getheader(ctx.response.headers, "location")
    if ctx.response.status in (301, 302, 303, 307, 308)
        if redirect && redirect_limit > 0 && getheader(ctx.response.headers, "location") != ""
            ctx.error = nothing
            ctx.should_retry = false
            reset(ctx.completed)
            old_host = ctx.request.uri.host
            ctx.request.uri = resolvereference(ctx.request.uri, getheader(ctx.response.headers, "location"))
            uri_ref = Ref{aws_uri}()
            url_str = string(ctx.request.uri)
            GC.@preserve url_str begin
                url_ref = Ref(aws_byte_cursor(sizeof(url_str), pointer(url_str)))
                aws_uri_init_parse(uri_ref, client.settings.allocator, url_ref)
            end
            ctx.request._uri = uri_ref[]
            ctx.request.method = newmethod(ctx.request.method, ctx.response.status, redirect_method)
            verbose >= 1 && @info "getting redirect client: $(ctx.request.uri.scheme), $(ctx.request.uri.host), $(getport(ctx.request._uri))"
            old_client = ctx.client
            ctx.client = getclient(ClientSettings(ctx.client.settings, ctx.request.uri.scheme, ctx.request.uri.host, getport(ctx.request._uri)))
            verbose >= 2 && @info "redirecting to $(string(ctx.request.uri)) with method: $(String(ctx.request.method))"
            if ctx.request.method == "GET"
                ctx.request.body = UInt8[]
            end
            if forwardheaders
                ctx.request.headers = filter(ctx.request.headers) do (header, _)
                    # false return values are filtered out
                    if header == "Host"
                        return false
                    elseif (header in SENSITIVE_HEADERS && !isdomainorsubdomain(ctx.request.uri.host, old_host))
                        return false
                    elseif ctx.request.method == "GET" && (ascii_lc_isequal(header, "content-type") || ascii_lc_isequal(header, "content-length"))
                        return false
                    else
                        return true
                    end
                end
            else
                ctx.request.headers = Header[]
            end
            empty!(ctx.response.headers)
            redirect_limit -= 1
            #TODO: should we rely on the retry strategy to handle this?
            # that means redirects count against your retries...
            # but also not sure we should be doing multiple requests w/ the same
            # retry token without recording success/scheduling a retry
            if old_client != ctx.client
                aws_retry_token_record_success(ctx.retry_token)
                aws_retry_token_release(ctx.retry_token)
                @goto acquire_retry_token
            else
                verbose >= 1 && @info "scheduling redirect retry: $(ctx.request.uri.host)"
                if aws_retry_strategy_schedule_retry(
                    ctx.retry_token,
                    error_type,
                    retry_ready[],
                    pointer_from_objref(ctx)
                ) != 0
                    ctx.error = CapturedException(aws_error(), Base.backtrace())
                    @goto error_fail
                end
                @goto request_wait
            end
        end
    elseif ctx.error !== nothing && ctx.should_retry
        verbose >= 1 && @warn "error making request, attempting retry: $(ctx.request.uri.host)" error=ctx.error
        ctx.error = nothing
        ctx.should_retry = false
        reset(ctx.completed)
        empty!(ctx.response.headers)
        verbose >= 1 && @info "scheduling error retry: $(ctx.request.uri.host)"
        ret = aws_retry_strategy_schedule_retry(
            ctx.retry_token,
            error_type,
            retry_ready[],
            pointer_from_objref(ctx)
        )
        if ret != 0
            ctx.error = CapturedException(aws_error(), Base.backtrace())
            @goto error_fail
        end
        @goto request_wait
    end

    # release our retry token
    ctx.error === nothing && aws_retry_token_record_success(ctx.retry_token)
    aws_retry_token_release(ctx.retry_token)
    ctx.retry_token = C_NULL
    ctx.error !== nothing && @goto error_fail
    return ctx.response

@label error_fail
    ctx.retry_token != C_NULL && aws_retry_token_release(ctx.retry_token)
    if ctx.error_response_body !== nothing
        # commit the temporary response body to the response body
        if ctx.response.body === nothing
            ctx.response.body = ctx.error_response_body
        elseif ctx.response.body isa AbstractVector{UInt8}
            copyto!(ctx.response.body, ctx.error_response_body)
        else
            write(ctx.response.body, ctx.error_response_body)
        end
    end
    throw(ctx.error)
end

const retry_ready = Ref{Ptr{Cvoid}}(C_NULL)

function c_retry_ready(token, error_code::Cint, ctx_ptr)
    ctx = unsafe_pointer_to_objref(ctx_ptr)
    if error_code != 0
        ctx.error = CapturedException(aws_error(error_code), Base.backtrace())
        ctx.should_retry = false # don't retry if our retry_schedule failed
        Threads.notify(ctx.completed)
        return
    end
    ctx.verbose >= 2 && @info "retry ready: $(ctx.request.uri.host)"
    c_on_acquired(C_NULL, 0, token, ctx_ptr)
    return
end

const on_acquired = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_acquired(retry_strategy, error_code, retry_token, ctx_ptr)
    ctx = unsafe_pointer_to_objref(ctx_ptr)
    if error_code != 0
        ctx.error = CapturedException(aws_error(error_code), Base.backtrace())
        ctx.should_retry = false # don't retry if we failed to get an initial retry_token
        Threads.notify(ctx.completed)
        return
    end
    ctx.retry_token = retry_token
    #NOTE: this is threadsafe based on our usage of the default aws connection manager implementation
    ctx.verbose >= 2 && @info "acquired retry token, acquiring connection: $(ctx.request.uri.host)"
    aws_http_connection_manager_acquire_connection(ctx.client.connection_manager, on_setup[], ctx_ptr)
end

get(a...; kw...) = request("GET", a...; kw...)
put(a...; kw...) = request("PUT", a...; kw...)
post(a...; kw...) = request("POST", a...; kw...)
delete(a...; kw...) = request("DELETE", a...; kw...)
patch(a...; kw...) = request("PATCH", a...; kw...)
head(a...; kw...) = request("HEAD", a...; kw...)
options(a...; kw...) = request("OPTIONS", a...; kw...)

macro remove_linenums!(expr)
    return esc(Base.remove_linenums!(expr))
end

macro client(modifier)
    return @remove_linenums! esc(quote
        get(a...; kw...) = ($__source__; request("GET", a...; kw...))
        put(a...; kw...) = ($__source__; request("PUT", a...; kw...))
        post(a...; kw...) = ($__source__; request("POST", a...; kw...))
        patch(a...; kw...) = ($__source__; request("PATCH", a...; kw...))
        head(a...; kw...) = ($__source__; request("HEAD", a...; kw...))
        delete(a...; kw...) = ($__source__; request("DELETE", a...; kw...))
        options(a...; kw...) = ($__source__; request("OPTIONS", a...; kw...))
        # open(f, a...; kw...) = ($__source__; request(a...; iofunction=f, kw...))
        function request(method, url, h=HTTP.Header[], b::HTTP.RequestBodyTypes=nothing;
            allocator=HTTP.default_aws_allocator(),
            headers=h,
            query=nothing,
            body::HTTP.RequestBodyTypes=b,
            client::Union{Nothing, HTTP.Client}=nothing,
            # redirect options
            redirect=true,
            redirect_limit=3,
            redirect_method=nothing,
            forwardheaders=true,
            # response options
            response_stream=nothing, # compat
            response_body=response_stream,
            decompress::Union{Nothing, Bool}=nothing,
            status_exception::Bool=true,
            retry_non_idempotent::Bool=false,
            modifier=nothing,
            verbose=0,
            kw...)
            $__source__
            HTTP.request(HTTP.Request(method, url, headers, body, allocator, query); modifier=$modifier(; kw...),
                client, redirect, redirect_limit, redirect_method, forwardheaders, response_body, decompress, status_exception, retry_non_idempotent, verbose)
        end
    end)
end