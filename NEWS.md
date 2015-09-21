Requests v0.3 Release Notes
=======

* The `data` argument to `post` can now accept a dictionary, in which case it is assumed that the data should be form-encoded.
* `Response.data` is now a `Vector{UInt8}` instead of a `String` to correctly handle binary responses. Use `bytestring(::Response)` to get back the response payload as a string.
* GnuTLS has been replaced with MbedTLS. Pass a `tls_conf` parameter to a request method with type `MbedTLS.SSLConfig` to override the default TLS settings.
* Redirects are automatically followed unless `allow_redirects=false` is used. `history(::Response)` will return the history of redirect responses that led to the given response.
* The request that generated a response is available with `requestfor(::Response)`.
* Cookies returned by the server can now be accessed with `cookies(::Response)`.
* A new streaming API is introduced for streaming out the payload of a response before it is complete. Call `get_streaming`, `post_streaming`, etc to get back a `ResponseStream` object. It has all the standard `IO` methods, such as `readbytes`, `nb_available`, etc. It also supports streaming in the body of a request with `write_chunk` if `send_body=false` is passed to `*_streaming`. See the relevant test in `runtests.jl` for an example.
