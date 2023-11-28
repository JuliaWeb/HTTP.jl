# HTTP.jl Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- ## [Unreleased] -->

## [v1.10.1] - 2023-11-28
### Changed
- Server errors are no longer serialized back to the client since this might leak sensitive
  information through the error message. ([#1126])
- When `show`ing `HTTP.Request` and `HTTP.Response` the values for the headers
  `Authorization`, `Proxy-Authorization`, `Cookie`, and `Set-Cookie` are masked with `*`s
  since they might include sensitive information. ([#1127])
### Fixed
- Restrict `HTTP.isredirect` to arguments of integer types. ([#1117])
- Fix `HTTP.getcookies` error when key doesn't exist. ([#1119])

## [v1.10.0] - 2023-09-18
### Fixed
- Don't retry on internal exceptions. ([#1110])
- Fix logging of errors to stringify instead of passing as exception keyword. ([#1092])

## [v1.9.16] - 2023-10-02
- Backport of [#1092].

## [v1.9.15] - 2023-09-10
### Fixed
- Mark recoverability of DNS errors correctly. ([#1088])
- Remove `readuntil` type-piracy. ([#1083])

## [v1.9.14] - 2023-07-12
### Changed
- Revert multithreaded connection attempts. ([#1078])

## [v1.9.13] - 2023-07-12
### Fixed
- Don't acquire IO lock within the connection lock. ([#1077])

## [v1.9.12] - 2023-07-12
### Fixed
- Fix keepalive related bug introduced in 1.9.8.

## [v1.9.11] - 2023-07-11
### Changed
- Make sure connection timeout doesn't count the time for lock-acquiring. ([#1075])
- Update the default connection timeout from 60 to 30 seconds. ([#1075])

## [v1.9.10] - 2023-07-10
### Changed
- Update the default connection timeout from 10 to 60 seconds.

## [v1.9.9] - 2023-07-10
### Fixed
- Ensure unused TCP connections are closed. ([#1073])

## [v1.9.8] - 2023-06-29
### Changed
- Try to connect to all adresses in parallel when establishing a connection. ([#1068])

## [v1.9.7] - 2023-06-22
### Changed
- Integrate with ExceptionUnwrapping.jl ([#1065])

## [v1.9.6] - 2023-05-27
### Fixed
- Allow retries if captured exception is recoverable. ([#1057])

## [v1.9.5] - 2023-05-19
### Fixed
- Make sure `set_default_connection_limit` usage applies also to already existing global
  pools. ([#1053])

## [v1.9.4] - 2023-05-14
### Fixed
- Fix usage of the lock added in v1.9.3. ([#1049]).

## [v1.9.3] - 2023-05-14
### Fixed
- Add another missing lock for updating request context ([#1048]).

## [v1.9.2] - 2023-05-13
### Fixed
- Add missing locks for updating request context ([#1046]).

## [v1.9.1] - 2023-05-11
-  Fix issue where error response body wasn't being set when readtimeout is specified.
   ([#1044])

## [v1.9.0] - 2023-05-11
### Changed
- The default TLS library have been changed from MbedTLS to OpenSSL. ([#1039])
- Use `Threads.@spawn` instead of `@async` in various places. ([#1039])

## [v1.8.1] - 2023-05-09
### Fixed
- Fix use of undefined variable in timeout code. ([#1043])

## [v1.8.0] - 2023-04-27
### Added
- Overload `URIs.queryparams` for `HTTP.Request` and `HTTP.Response`. ([#1012])
### Changed
- Request bodies as dictionaries have been widened from `Dict` to `AbstractDict`. ([#1029])
- The connection pool implementation have been extracted to the ConcurrentUtilities.jl
  package. ([#1034])
### Fixed
- Remove unused `IniFile` dependency. ([#1013])
- Write cookie separator with a space. ([#1016])
- Parse `set-cookie` expire with a trailing GMT. ([#1035])

## [v1.7.4] - 2023-01-24
### Fixed
- Fix a segfault related to missing locks in calls to libuv. ([#999])

## [v1.7.2] - 2023-01-13
### Added
- `HTTP.download` now automatically decompresses gzip'd content (similar to `HTTP.request`).
  ([#986])
### Fixed
- Release old connections from the correct socket pool. ([#998])

## [v1.7.1] - 2023-01-12
### Fixed
- Allow the keyword argument `retry_delays` to be of any type (not just
  `ExponentialBackOff`). ([#993])
- Remove the default 60 second read timeout, and reduce default connection timeout to 10
  seconds. (These were added in 1.7.0.) ([#994])

## [v1.7.0] - 2023-01-12
### Added
- Allow passing pre-allocated buffer for response body. ([#984])
- `HTTP.StatusCodes` module/namespace with all HTTP status code and corresponding status
  texts. ([#982])
### Changed
- Add a default timeout of 60 seconds client side .([#992])
- The default value of `keepalive::Bool` for TCP connections have been updated to `true`.
  ([#991])
### Fixed
- Parametrize the internal Connection type on the socket type to avoid some type
  instabilities. ([#983])
- Account for response status when retrying. ([#990])

## [v1.6.3] - 2023-01-03
### Fixed
- Slightly reduce memory allocations when reading/writing HTTP messages. ([#950])
- Set line info for the `@clien` macro to the macro call site. ([#981])

## [v1.6.2] - 2022-12-15
### Changed
- Pass the response body as argument to the `retry_check` user function introduced in 1.6.0.
  ([#976])

## [v1.6.1] - 2022-12-14
### Fixed
- Fix a bug related to response bodies not being set after StatusError exceptions. ([#975])

## [v1.6.0] - 2022-12-11
### Added
- Configurable retry logic through the `retry_delays` and `retry_check` keyword arguments of
  `HTTP.request` and similar methods. ([#974])
### Fixed
- Do not turn `HEAD` requests to `GET` by default through redirects. ([#967])
- Fix some thread-related caches for interactive threadpools. ([#972])

## [v1.5.5] - 2022-11-18
### Fixed
- Allow retrying requests after write failures. ([#964])

## [v1.5.4] - 2022-11-14
### Fixed
- Update `[compat]` to allow LoggingExtras.jl version 1. ([#963])

## [v1.5.3] - 2022-11-09
### Fixed
- Use `@sync` instead of `@spawn` when interactive threads are not supported. ([#960])

## [v1.5.2] - 2022-11-03
### Changed
- The server task is spawned on an interactive thread if available. ([#955])
### Fixed
- Fix a bug related to rethrowing exceptions in timeout handling. ([#942])

## [v1.5.1] - 2022-10-20
### Added
- Number of retries is recorded in the request context. ([#946])
### Fixed
- Fix socket type for ssl upgrade when the the protocals differ. ([#943])

## [v1.5.0] - 2022-10-17
### Added
- The function `HTTP.set_default_connection_limit!(::Int)` have been added. ([#940])
### Fixed
- Various fixes to the optional OpenSSL integration. ([#941])

## [v1.4.1] - 2022-10-11
### Added
- Support for specifying `CA_BUNDLE` via environment variables.. ([#925], [#933])
### Fixed
- Fix `DEBUG_LEVEL` handling to propagate to the logger correctly. ([#929])
- Fix a server side crash when issuing HTTP request to a HTTPS server. ([#934], [#935])

## [v1.4.0] - 2022-09-22
### Added
- Support for using OpenSSL for TLS connections. MbedTLS is still the default. ([#928])
### Changed
- Better verification and error reporting of invalid headers. ([#918], [#919])
### Fixed
- Fix vararg function definition of `HTTP.head`.

## [v1.3.3] - 2022-08-26
### Fixed
- Revert faulty bugfix from previous release. ([#914])

## [v1.3.2] - 2022-08-25
### Fixed
- Fix a bug in idle connection monitoring. ([#912])

## [v1.3.1] - 2022-08-24
### Fixed
- Fix a bug related to read timeouts. ([#911])

## [v1.3.0] - 2022-08-24
### Added
- `HTTP.listen!` now support the keyword argument `listenany::Bool` to listen to any
  available port. The resulting port can be obtained from the returned `Server` object by
  `HTTP.port`. ([#905])
- Gzip decompression of request bodies can now be forced by passing `decompress=true` to
  `HTTP.request`. ([#904])
### Fixed
- Fix a stack overflow error in `HTTP.download` when the URI had a trailing `/`. ([#897])
- Fix a bug related to not accounting for timeouts correctly. ([#909], [#910])

## [v1.2.1] - 2022-08-10
### Fixed
- Fix an bug in idle connection monitoring. ([#901])

## [v1.2.0] - 2022-07-18
### Added
- Add ability to "hook" a middleware into Router post-matching. ([#886])

## [v1.1.0] - 2022-07-17
### Added
- The response body is now preserved when retrying/redirecting. ([#876])
- `HTTP.getparam` has been added to fetch one routing parameter (in addition to the existing
  `HTTP.getparams`). ([#880])
- `HTTP.removeheader` has been added. ([#883])
### Changed
- Allow any string for parameter names in router. ([#871], [#872])
### Fixed
- The acquire/release usage from the connection pool have been adjusted to fix a possible
  hang when concurrently issuing a large number of requests. ([#882])
- A bug in the connection reuse logic has been fixed. ([#875], [#885])

## [v1.0.5] - 2022-06-24
### Added
- Store the original registered route path when Router matches. ([#866])
### Fixed
- Fix use of undefined variable in cookie-code. ([#867])

## [v1.0.4] - 2022-06-21
### Fixed
- Ensure underlying Connection gets closed in websocket close sequence. ([#865])

## [v1.0.3] - 2022-06-21
### Fixed
- Ensure a Request accounts correctly for isredirect/retryable. ([#864])

## [v1.0.2] - 2022-06-20
### Fixed
- Fix some issues with automatic gzip decompression. ([#861])

## [v1.0.1] - 2022-06-19
### Fixed
- Fix `HTTP.listen` with providec TCP server. ([#857])
- Add some deprecation warnings to help upgrade from 0.9.x to 1.0.x. ([#858])

## [v1.0.0] - 2022-06-19
### Added
- The response body for responses with `Content-Encoding: gzip` are now automatically
  decompressed. Pass `decompress=false` to `HTTP.request` to disable. ([#838])
- `HTTP.parse_multipart_form` can now parse responses (as well as requests). ([#817])
- `HTTP.listen!` has been added as a non-blocking version of `HTTP.listen`. It returns a
  `Server` object which supports `wait`, `close` and `forceclose`. See documentation for
  details. ([#854])
### Changed
- HTTP.jl no longer calls `close` on streams given with the `response_stream` keyword
  argument to `HTTP.request` and friends. If you relied on this behavior you now have
  to do it manually, e.g.
  ```julia
  io = ...
  HTTP.request(...; response_stream = io)
  close(io)
  ```
  ([#543], [#752], [#775]).
- The internal client request layer stack have been reworked to be value based instead of
  type based. This is breaking if you implement custom layers but not for regular client
  usage. Refer to the documentation for how to update. ([#789])
- The server side Handlers/Router framework have been reworked. Refer to the documentation
  for how to update. ([#818])
- The default value (optional third argument) to `HTTP.header` can now be of any type (not
  just `AbstractString`). ([#820])
- HTTP.jl now attempts to reencode malformed, non-ascii, headers from Latin-1 to UTF-8.
  ([#830])
- Headers with the empty string as their value are now omitted from requests (this matches
  the behavior of e.g. `curl`). ([#831])
- Requests to localhost are no longer proxied. ([#833])
- The cookie-code have been reworked. In particular it is now safe to use concurrently.
  ([#836])
- The websockets code have been reworked. ([#843])
- HTTP.jl exception types are now more consistent. ([#846])
### Removed
- Support for "pipelined requests" have been removed in the client implementation. The
  keyword arguments to `HTTP.request` related to this feature (`pipeline_limit` and
  `reuse_limit`) are now ignored ([#783]).

## [v0.9.17] - 2021-11-17
### Fixed
- Correctly throw an `EOFError` if the connection is closed with remaining bytes
  to be transferred ([#778], [#781]).

## [v0.9.16] - 2021-09-29
See changes for 0.9.15: this release is equivalent to 0.9.15 with [#752] reverted.
[#752] might be included in a future breaking release instead, see [#774].

## [v0.9.15] - 2021-09-27
**Note:** This release have been pulled back since [#752] turned out to be breaking.
### Changed
- **Reverted in 0.9.16**
  HTTP.jl no longer calls `close` on streams given with the `response_stream` keyword
  argument to `HTTP.request` and friends. If it is required to close the stream after the
  request you now have to do it manually, e.g.
  ```julia
  io = ...
  HTTP.request(...; response_stream = io)
  close(io)
  ```
  ([#543], [#752]).
- The `Content-Type` header for requests with `HTTP.Form` bodies is now automatically
  set also for `PUT` requests (just like `POST` requests) ([#770], [#740]).
### Fixed
- Fix faulty error messages from an internal macro ([#753]).
- Silence ECONNRESET errors on more systems ([#547], [#763], [#764]).
- Use `Content-Disposition` from original request in case of a 3xx response ([#760], [#761]).
- Fix cookie handling to be case-insensitive for `Set-Cookie` headers ([#765], [#766]).

## [v0.9.14] - 2021-08-31
### Changed
- Improved memory use and performance of multipart parsing ([#745]).
### Fixed
- `HTTP.Response` now accept any `Integer` as the return status (not just `Int`) ([#734], [#742]).

## [v0.9.13] - 2021-08-01
### Changed
- The call stack now has a `TopLayer` inserted at the top to simplify adding new layers at
  the top ([#737]).

## [v0.9.12] - 2021-07-01
### Fixed
- Fix a JSON detection issue in `HTTP.sniff` for negative numeric values ([#730]).

## [v0.9.11] - 2021-06-30
### Changed
- "Connection closed by peer" errors are now emitted as `Debug`-level messages (instead of `Error`-level) ([#727]).
### Fixed
- Fix websocket disconnection errors ([#723]).
- Reduced allocations for some internals functions used for e.g. header comparison ([#725]).

## [v0.9.10] - 2021-05-30
### Fixed
- Fix access logging to also log internal server errors ([#717]).
- Fix a possible crash in access logging of remote IP when the connection have been closed ([#718]).

## [v0.9.9] - 2021-05-23
### Added
- Access logging functionality to `HTTP.listen` and `HTTP.serve` ([#713]).
### Fixed
- Include `Host` header for `CONNECT` proxy requests ([#714]).

## [v0.9.8] - 2021-05-02
### Fixed
- URLs are now checked for missing protocol and hostname when making requests ([#703]).
- Fix an issue where relative HTTP 3xx redirects would not resolve the new URL correctly
  by upgrading the URIs dependency ([#707]).
- Fix automatic detection of filename in `HTTP.download` to (i) not include any query
  parameters and (ii) use the original request URL instead of any redirect URLs ([#706]).
### Changed
- Improvements to internal allocation of buffers to decrease package load time ([#704]).

## [v0.9.7] - 2021-04-28
### Added
- Implement `Sockets.getpeername(::HTTP.Stream)` for getting the client IP address and port from a `HTTP.Stream` ([#702]).

## [v0.9.6] - 2021-04-27
### Added
- New function `HTTP.statustext` for getting the string representation of a HTTP status code ([#688]).
- New exception `ReadTimeoutError` which is thrown for request that time out ([#693]).
### Changed
- Un-deprecate `HTTP.status`, `HTTP.headers`, `HTTP.body`, `HTTP.method`, and `HTTP.uri` ([#682]).
### Fixed
- Fixes and improvements to rate limiting in `HTTP.listen` and `HTTP.serve` ([#701]).

## [v0.9.5] - 2021-02-23
### Fixed
- Fix implicitly added `Host` header for `HTTP.request` (and friends) to include the port
  for non-standard ports ([#680]).

## [v0.9.4] - 2021-02-23
### Changed
- [NetworkOptions.jl](https://github.com/JuliaLang/NetworkOptions.jl)'s
  [`verify_host`](https://github.com/JuliaLang/NetworkOptions.jl#verify_host) is now used
  for the default value for host verification ([#678]).
### Fixed
- Ignore `HTTP_PROXY` and `HTTPS_PROXY` environment variables if they are set to the empty
  string ([#674]).
- When trying to establish a connection, try all IP addresses found for the host instead of
  just the first one ([#675]).

## [v0.9.3] - 2021-02-10
### Added
- New keyword `max_connections::Int` to `HTTP.listen` for specifying maximum value of
  concurrent active connections ([#647]).
### Changed
- The header `Accept: */*` is now added by default for `HTTP.request` and friends (this
  mirrors the behavior of e.g. `curl` and Python's `request`) ([#666]).

## [v0.9.2] - 2020-12-22
### Changed
- If a proxy specification includes userinfo it is now added as the
  `Proxy-Authorization: Basic XXX` header ([#640]).
### Fixed
- Proxy specifications using the environment variables `HTTP_PROXY`/`HTTPS_PROXY` are now
  checked, previously only the lowercase versions `http_proxy`/`https_proxy` where
  checked ([#648]).

## [v0.9.1] - 2020-12-04
### Changed
- TCP connections are now flushed on `closewrite` which can improve latency in some cases
   ([#635]).
- Callbacks to `HTTP.listen` that never calls `startwrite` now throw and return
  `500 Internal Server Error` to the client ([#636]).
- `closebody` does not error if closing bytes could not be written ([#546]).

## [v0.9.0] - 2020-11-12
### Added
- New keyword argument `on_shutdown::Union{Function,Vector{Function}}` to `HTTP.listen`/
  `HTTP.serve` for registering callback function to be run at server shutdown ([#599]).
- New functions `insert_default!` and `remove_default!` for inserting/removing layers
  in the default stack ([#608]).
- New keyword argument `boundary` to `HTTP.Form` for specifying the boundary for multipart
  requests ([#613], [#615]).
### Changed
- The internal `HTTP.URIs` module have been factored out to an independent package which
  `HTTP.jl` now depends on ([#616]).
### Fixed
- Fix a formatting bug in progress reporting in `HTTP.download` ([#601]).
- Fix a case where bad HTTPS requests to would cause the HTTP.jl server to throw ([#602]).
- The correct host/port is now logged even if the server is provided with the `server`
  keyword argument to `HTTP.listen`/`HTTP.serve` ([#611]).
- Fix some outdated internal calls that would throw when passing a `connect_timeout` to
  `HTTP.request` and friends ([#619]).


[Unreleased]: https://github.com/JuliaWeb/HTTP.jl/compare/v1.10.1...HEAD


<!-- Links generated by Changelog.jl -->

[v0.9.0]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.0
[v0.9.1]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.1
[v0.9.2]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.2
[v0.9.3]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.3
[v0.9.4]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.4
[v0.9.5]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.5
[v0.9.6]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.6
[v0.9.7]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.7
[v0.9.8]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.8
[v0.9.9]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.9
[v0.9.10]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.10
[v0.9.11]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.11
[v0.9.12]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.12
[v0.9.13]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.13
[v0.9.14]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.14
[v0.9.15]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.15
[v0.9.16]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.16
[v0.9.17]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v0.9.17
[v1.0.0]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.0.0
[v1.0.1]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.0.1
[v1.0.2]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.0.2
[v1.0.3]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.0.3
[v1.0.4]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.0.4
[v1.0.5]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.0.5
[v1.1.0]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.1.0
[v1.2.0]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.2.0
[v1.2.1]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.2.1
[v1.3.0]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.3.0
[v1.3.1]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.3.1
[v1.3.2]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.3.2
[v1.3.3]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.3.3
[v1.4.0]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.4.0
[v1.4.1]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.4.1
[v1.5.0]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.5.0
[v1.5.1]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.5.1
[v1.5.2]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.5.2
[v1.5.3]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.5.3
[v1.5.4]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.5.4
[v1.5.5]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.5.5
[v1.6.0]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.6.0
[v1.6.1]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.6.1
[v1.6.2]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.6.2
[v1.6.3]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.6.3
[v1.7.0]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.7.0
[v1.7.1]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.7.1
[v1.7.2]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.7.2
[v1.7.4]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.7.4
[v1.8.0]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.8.0
[v1.8.1]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.8.1
[v1.9.0]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.0
[v1.9.1]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.1
[v1.9.2]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.2
[v1.9.3]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.3
[v1.9.4]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.4
[v1.9.5]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.5
[v1.9.6]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.6
[v1.9.7]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.7
[v1.9.8]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.8
[v1.9.9]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.9
[v1.9.10]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.10
[v1.9.11]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.11
[v1.9.12]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.12
[v1.9.13]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.13
[v1.9.14]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.14
[v1.9.15]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.15
[v1.9.16]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.9.16
[v1.10.0]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.10.0
[v1.10.1]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.10.1
[#543]: https://github.com/JuliaWeb/HTTP.jl/issues/543
[#546]: https://github.com/JuliaWeb/HTTP.jl/issues/546
[#547]: https://github.com/JuliaWeb/HTTP.jl/issues/547
[#599]: https://github.com/JuliaWeb/HTTP.jl/issues/599
[#601]: https://github.com/JuliaWeb/HTTP.jl/issues/601
[#602]: https://github.com/JuliaWeb/HTTP.jl/issues/602
[#608]: https://github.com/JuliaWeb/HTTP.jl/issues/608
[#611]: https://github.com/JuliaWeb/HTTP.jl/issues/611
[#613]: https://github.com/JuliaWeb/HTTP.jl/issues/613
[#615]: https://github.com/JuliaWeb/HTTP.jl/issues/615
[#616]: https://github.com/JuliaWeb/HTTP.jl/issues/616
[#619]: https://github.com/JuliaWeb/HTTP.jl/issues/619
[#635]: https://github.com/JuliaWeb/HTTP.jl/issues/635
[#636]: https://github.com/JuliaWeb/HTTP.jl/issues/636
[#640]: https://github.com/JuliaWeb/HTTP.jl/issues/640
[#647]: https://github.com/JuliaWeb/HTTP.jl/issues/647
[#648]: https://github.com/JuliaWeb/HTTP.jl/issues/648
[#666]: https://github.com/JuliaWeb/HTTP.jl/issues/666
[#674]: https://github.com/JuliaWeb/HTTP.jl/issues/674
[#675]: https://github.com/JuliaWeb/HTTP.jl/issues/675
[#678]: https://github.com/JuliaWeb/HTTP.jl/issues/678
[#680]: https://github.com/JuliaWeb/HTTP.jl/issues/680
[#682]: https://github.com/JuliaWeb/HTTP.jl/issues/682
[#688]: https://github.com/JuliaWeb/HTTP.jl/issues/688
[#693]: https://github.com/JuliaWeb/HTTP.jl/issues/693
[#701]: https://github.com/JuliaWeb/HTTP.jl/issues/701
[#702]: https://github.com/JuliaWeb/HTTP.jl/issues/702
[#703]: https://github.com/JuliaWeb/HTTP.jl/issues/703
[#704]: https://github.com/JuliaWeb/HTTP.jl/issues/704
[#706]: https://github.com/JuliaWeb/HTTP.jl/issues/706
[#707]: https://github.com/JuliaWeb/HTTP.jl/issues/707
[#713]: https://github.com/JuliaWeb/HTTP.jl/issues/713
[#714]: https://github.com/JuliaWeb/HTTP.jl/issues/714
[#717]: https://github.com/JuliaWeb/HTTP.jl/issues/717
[#718]: https://github.com/JuliaWeb/HTTP.jl/issues/718
[#723]: https://github.com/JuliaWeb/HTTP.jl/issues/723
[#725]: https://github.com/JuliaWeb/HTTP.jl/issues/725
[#727]: https://github.com/JuliaWeb/HTTP.jl/issues/727
[#730]: https://github.com/JuliaWeb/HTTP.jl/issues/730
[#734]: https://github.com/JuliaWeb/HTTP.jl/issues/734
[#737]: https://github.com/JuliaWeb/HTTP.jl/issues/737
[#740]: https://github.com/JuliaWeb/HTTP.jl/issues/740
[#742]: https://github.com/JuliaWeb/HTTP.jl/issues/742
[#745]: https://github.com/JuliaWeb/HTTP.jl/issues/745
[#752]: https://github.com/JuliaWeb/HTTP.jl/issues/752
[#753]: https://github.com/JuliaWeb/HTTP.jl/issues/753
[#760]: https://github.com/JuliaWeb/HTTP.jl/issues/760
[#761]: https://github.com/JuliaWeb/HTTP.jl/issues/761
[#763]: https://github.com/JuliaWeb/HTTP.jl/issues/763
[#764]: https://github.com/JuliaWeb/HTTP.jl/issues/764
[#765]: https://github.com/JuliaWeb/HTTP.jl/issues/765
[#766]: https://github.com/JuliaWeb/HTTP.jl/issues/766
[#770]: https://github.com/JuliaWeb/HTTP.jl/issues/770
[#774]: https://github.com/JuliaWeb/HTTP.jl/issues/774
[#775]: https://github.com/JuliaWeb/HTTP.jl/issues/775
[#778]: https://github.com/JuliaWeb/HTTP.jl/issues/778
[#781]: https://github.com/JuliaWeb/HTTP.jl/issues/781
[#783]: https://github.com/JuliaWeb/HTTP.jl/issues/783
[#789]: https://github.com/JuliaWeb/HTTP.jl/issues/789
[#817]: https://github.com/JuliaWeb/HTTP.jl/issues/817
[#818]: https://github.com/JuliaWeb/HTTP.jl/issues/818
[#820]: https://github.com/JuliaWeb/HTTP.jl/issues/820
[#830]: https://github.com/JuliaWeb/HTTP.jl/issues/830
[#831]: https://github.com/JuliaWeb/HTTP.jl/issues/831
[#833]: https://github.com/JuliaWeb/HTTP.jl/issues/833
[#836]: https://github.com/JuliaWeb/HTTP.jl/issues/836
[#838]: https://github.com/JuliaWeb/HTTP.jl/issues/838
[#843]: https://github.com/JuliaWeb/HTTP.jl/issues/843
[#846]: https://github.com/JuliaWeb/HTTP.jl/issues/846
[#854]: https://github.com/JuliaWeb/HTTP.jl/issues/854
[#857]: https://github.com/JuliaWeb/HTTP.jl/issues/857
[#858]: https://github.com/JuliaWeb/HTTP.jl/issues/858
[#861]: https://github.com/JuliaWeb/HTTP.jl/issues/861
[#864]: https://github.com/JuliaWeb/HTTP.jl/issues/864
[#865]: https://github.com/JuliaWeb/HTTP.jl/issues/865
[#866]: https://github.com/JuliaWeb/HTTP.jl/issues/866
[#867]: https://github.com/JuliaWeb/HTTP.jl/issues/867
[#871]: https://github.com/JuliaWeb/HTTP.jl/issues/871
[#872]: https://github.com/JuliaWeb/HTTP.jl/issues/872
[#875]: https://github.com/JuliaWeb/HTTP.jl/issues/875
[#876]: https://github.com/JuliaWeb/HTTP.jl/issues/876
[#880]: https://github.com/JuliaWeb/HTTP.jl/issues/880
[#882]: https://github.com/JuliaWeb/HTTP.jl/issues/882
[#883]: https://github.com/JuliaWeb/HTTP.jl/issues/883
[#885]: https://github.com/JuliaWeb/HTTP.jl/issues/885
[#886]: https://github.com/JuliaWeb/HTTP.jl/issues/886
[#897]: https://github.com/JuliaWeb/HTTP.jl/issues/897
[#901]: https://github.com/JuliaWeb/HTTP.jl/issues/901
[#904]: https://github.com/JuliaWeb/HTTP.jl/issues/904
[#905]: https://github.com/JuliaWeb/HTTP.jl/issues/905
[#909]: https://github.com/JuliaWeb/HTTP.jl/issues/909
[#910]: https://github.com/JuliaWeb/HTTP.jl/issues/910
[#911]: https://github.com/JuliaWeb/HTTP.jl/issues/911
[#912]: https://github.com/JuliaWeb/HTTP.jl/issues/912
[#914]: https://github.com/JuliaWeb/HTTP.jl/issues/914
[#918]: https://github.com/JuliaWeb/HTTP.jl/issues/918
[#919]: https://github.com/JuliaWeb/HTTP.jl/issues/919
[#925]: https://github.com/JuliaWeb/HTTP.jl/issues/925
[#928]: https://github.com/JuliaWeb/HTTP.jl/issues/928
[#929]: https://github.com/JuliaWeb/HTTP.jl/issues/929
[#933]: https://github.com/JuliaWeb/HTTP.jl/issues/933
[#934]: https://github.com/JuliaWeb/HTTP.jl/issues/934
[#935]: https://github.com/JuliaWeb/HTTP.jl/issues/935
[#940]: https://github.com/JuliaWeb/HTTP.jl/issues/940
[#941]: https://github.com/JuliaWeb/HTTP.jl/issues/941
[#942]: https://github.com/JuliaWeb/HTTP.jl/issues/942
[#943]: https://github.com/JuliaWeb/HTTP.jl/issues/943
[#946]: https://github.com/JuliaWeb/HTTP.jl/issues/946
[#950]: https://github.com/JuliaWeb/HTTP.jl/issues/950
[#955]: https://github.com/JuliaWeb/HTTP.jl/issues/955
[#960]: https://github.com/JuliaWeb/HTTP.jl/issues/960
[#963]: https://github.com/JuliaWeb/HTTP.jl/issues/963
[#964]: https://github.com/JuliaWeb/HTTP.jl/issues/964
[#967]: https://github.com/JuliaWeb/HTTP.jl/issues/967
[#972]: https://github.com/JuliaWeb/HTTP.jl/issues/972
[#974]: https://github.com/JuliaWeb/HTTP.jl/issues/974
[#975]: https://github.com/JuliaWeb/HTTP.jl/issues/975
[#976]: https://github.com/JuliaWeb/HTTP.jl/issues/976
[#981]: https://github.com/JuliaWeb/HTTP.jl/issues/981
[#982]: https://github.com/JuliaWeb/HTTP.jl/issues/982
[#983]: https://github.com/JuliaWeb/HTTP.jl/issues/983
[#984]: https://github.com/JuliaWeb/HTTP.jl/issues/984
[#986]: https://github.com/JuliaWeb/HTTP.jl/issues/986
[#990]: https://github.com/JuliaWeb/HTTP.jl/issues/990
[#991]: https://github.com/JuliaWeb/HTTP.jl/issues/991
[#992]: https://github.com/JuliaWeb/HTTP.jl/issues/992
[#993]: https://github.com/JuliaWeb/HTTP.jl/issues/993
[#994]: https://github.com/JuliaWeb/HTTP.jl/issues/994
[#998]: https://github.com/JuliaWeb/HTTP.jl/issues/998
[#999]: https://github.com/JuliaWeb/HTTP.jl/issues/999
[#1012]: https://github.com/JuliaWeb/HTTP.jl/issues/1012
[#1013]: https://github.com/JuliaWeb/HTTP.jl/issues/1013
[#1016]: https://github.com/JuliaWeb/HTTP.jl/issues/1016
[#1029]: https://github.com/JuliaWeb/HTTP.jl/issues/1029
[#1034]: https://github.com/JuliaWeb/HTTP.jl/issues/1034
[#1035]: https://github.com/JuliaWeb/HTTP.jl/issues/1035
[#1039]: https://github.com/JuliaWeb/HTTP.jl/issues/1039
[#1043]: https://github.com/JuliaWeb/HTTP.jl/issues/1043
[#1044]: https://github.com/JuliaWeb/HTTP.jl/issues/1044
[#1046]: https://github.com/JuliaWeb/HTTP.jl/issues/1046
[#1048]: https://github.com/JuliaWeb/HTTP.jl/issues/1048
[#1049]: https://github.com/JuliaWeb/HTTP.jl/issues/1049
[#1053]: https://github.com/JuliaWeb/HTTP.jl/issues/1053
[#1057]: https://github.com/JuliaWeb/HTTP.jl/issues/1057
[#1065]: https://github.com/JuliaWeb/HTTP.jl/issues/1065
[#1068]: https://github.com/JuliaWeb/HTTP.jl/issues/1068
[#1073]: https://github.com/JuliaWeb/HTTP.jl/issues/1073
[#1075]: https://github.com/JuliaWeb/HTTP.jl/issues/1075
[#1077]: https://github.com/JuliaWeb/HTTP.jl/issues/1077
[#1078]: https://github.com/JuliaWeb/HTTP.jl/issues/1078
[#1083]: https://github.com/JuliaWeb/HTTP.jl/issues/1083
[#1088]: https://github.com/JuliaWeb/HTTP.jl/issues/1088
[#1092]: https://github.com/JuliaWeb/HTTP.jl/issues/1092
[#1110]: https://github.com/JuliaWeb/HTTP.jl/issues/1110
[#1117]: https://github.com/JuliaWeb/HTTP.jl/issues/1117
[#1119]: https://github.com/JuliaWeb/HTTP.jl/issues/1119
[#1126]: https://github.com/JuliaWeb/HTTP.jl/issues/1126
[#1127]: https://github.com/JuliaWeb/HTTP.jl/issues/1127
