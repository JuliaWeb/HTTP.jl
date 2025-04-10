get(a...; kw...) = request("GET", a...; kw...)
put(a...; kw...) = request("PUT", a...; kw...)
post(a...; kw...) = request("POST", a...; kw...)
delete(a...; kw...) = request("DELETE", a...; kw...)
patch(a...; kw...) = request("PATCH", a...; kw...)
head(a...; kw...) = request("HEAD", a...; kw...)
options(a...; kw...) = request("OPTIONS", a...; kw...)

const COOKIEJAR = CookieJar()

_something(x, y) = x === nothing ? y : x

# main entrypoint for making an HTTP request
# can provide method, url, headers, body, along with various keyword arguments
function request(method, url, h=Header[], b::RequestBodyTypes=nothing;
    allocator=default_aws_allocator(),
    headers=h,
    body::RequestBodyTypes=b,
    chunkedbody=nothing,
    username=nothing,
    password=nothing,
    bearer=nothing,
    query=nothing,
    client::Union{Nothing, Client}=nothing,
    # redirect options
    redirect=true,
    redirect_limit=3,
    redirect_method=nothing,
    forwardheaders=true,
    # cookie options
    cookies=true,
    cookiejar::CookieJar=COOKIEJAR,
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
    kw...)
    uri = parseuri(url, query, allocator)
    return with_redirect(allocator, method, uri, headers, body, redirect, redirect_limit, redirect_method, forwardheaders) do method, uri, headers, body
        reqclient = @something(client, getclient(ClientSettings(scheme(uri), host(uri), getport(uri); allocator=allocator, kw...)))::Client
        with_retry_token(reqclient) do
            resp = with_connection(reqclient) do conn
                http2 = aws_http_connection_get_version(conn) == AWS_HTTP_VERSION_2
                path = resource(uri)
                with_request(reqclient, method, path, headers, body, chunkedbody, decompress, (username !== nothing && password !== nothing) ? "$username:$password" : userinfo(uri), bearer, modifier, http2, cookies, cookiejar, verbose) do req
                    if response_body isa AbstractVector{UInt8}
                        ref = Ref(1)
                        GC.@preserve ref begin
                            on_stream_response_body = BufferOnResponseBody(response_body, Base.unsafe_convert(Ptr{Int}, ref))
                            with_stream(conn, req, chunkedbody, on_stream_response_body, decompress, http2, readtimeout, allocator)
                        end
                    elseif response_body isa IO
                        on_stream_response_body = IOOnResponseBody(response_body)
                        with_stream(conn, req, chunkedbody, on_stream_response_body, decompress, http2, readtimeout, allocator)
                    else
                        with_stream(conn, req, chunkedbody, response_body, decompress, http2, readtimeout, allocator)
                    end
                end
            end
            # status error check
            if status_exception && iserror(resp)
                throw(StatusError(method, uri, resp))
            end
            return resp
        end
    end
end
