# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Fixed
- Include Host header for CONNECT proxy requests ([#714])

## [0.9.8] - 2020-05-02
### Fixed
- URLs are now checked for missing protocol and hostname when making requests ([#703]).
- Fix an issue where relative HTTP 3xx redirects would not resolve the new URL correctly
  by upgrading the URIs dependency ([#707]).
- Fix automatic detection of filename in `HTTP.download` to (i) not include any query
  parameters and (ii) use the original request URL instead of any redirect URLs ([#706]).
### Changed
- Improvements to internal allocation of buffers to decrease package load time ([#704]).

## [0.9.7] - 2020-04-28
### Added
- Implement `Sockets.getpeername(::HTTP.Stream)` for getting the client IP address and port from a `HTTP.Stream` ([#702]).

## [0.9.6] - 2020-04-27
### Added
- New function `HTTP.statustext` for getting the string representation of a HTTP status code ([#688]).
- New exception `ReadTimeoutError` which is thrown for request that time out ([#693]).
### Changed
- Un-deprecate `HTTP.status`, `HTTP.headers`, `HTTP.body`, `HTTP.method`, and `HTTP.uri` ([#682]).
### Fixed
- Fixes and improvements to rate limiting in `HTTP.listen` and `HTTP.serve` ([#701]).

## [0.9.5] - 2020-02-23
### Fixed
- Fix implicitly added `Host` header for `HTTP.request` (and friends) to include the port
  for non-standard ports ([#680]).

## [0.9.4] - 2020-02-23
### Changed
- [NetworkOptions.jl](https://github.com/JuliaLang/NetworkOptions.jl)'s
  [`verify_host`](https://github.com/JuliaLang/NetworkOptions.jl#verify_host) is now used
  for the default value for host verification ([#678]).
### Fixed
- Ignore `HTTP_PROXY` and `HTTPS_PROXY` environment variables if they are set to the empty
  string ([#674]).
- When trying to establish a connection, try all IP addresses found for the host instead of
  just the first one ([#675]).

## [0.9.3] - 2020-02-10
### Added
- New keyword `max_connections::Int` to `HTTP.listen` for specifying maximum value of
  concurrent active connections ([#647]).
### Changed
- The header `Accept: */*` is now added by default for `HTTP.request` and friends (this
  mirrors the behavior of e.g. `curl` and Python's `request`) ([#666]).

## [0.9.2] - 2020-12-22
### Changed
- If a proxy specification includes userinfo it is now added as the
  `Proxy-Authorization: Basic XXX` header ([#640]).
### Fixed
- Proxy specifications using the environment variables `HTTP_PROXY`/`HTTPS_PROXY` are now
  checked, previously only the lowercase versions `http_proxy`/`https_proxy` where
  checked ([#648]).

## [0.9.1] - 2020-12-04
### Changed
- TCP connections are now flushed on `closewrite` which can improve latency in some cases
   ([#635]).
- Callbacks to `HTTP.listen` that never calls `startwrite` now throw and return
  `500 Internal Server Error` to the client ([#636]).
- `closebody` does not error if closing bytes could not be written ([#546]).

## [0.9.0] - 2020-11-12
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


[Unreleased]: https://github.com/JuliaWeb/HTTP.jl/compare/v0.9.8...HEAD
[0.9.8]: https://github.com/JuliaWeb/HTTP.jl/compare/v0.9.7...v0.9.8
[0.9.7]: https://github.com/JuliaWeb/HTTP.jl/compare/v0.9.6...v0.9.7
[0.9.6]: https://github.com/JuliaWeb/HTTP.jl/compare/v0.9.5...v0.9.6
[0.9.5]: https://github.com/JuliaWeb/HTTP.jl/compare/v0.9.4...v0.9.5
[0.9.4]: https://github.com/JuliaWeb/HTTP.jl/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/JuliaWeb/HTTP.jl/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/JuliaWeb/HTTP.jl/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/JuliaWeb/HTTP.jl/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/JuliaWeb/HTTP.jl/compare/v0.8.19...v0.9.0


[#546]: https://github.com/JuliaWeb/HTTP.jl/pull/546
[#599]: https://github.com/JuliaWeb/HTTP.jl/pull/599
[#601]: https://github.com/JuliaWeb/HTTP.jl/pull/601
[#602]: https://github.com/JuliaWeb/HTTP.jl/pull/602
[#608]: https://github.com/JuliaWeb/HTTP.jl/pull/608
[#611]: https://github.com/JuliaWeb/HTTP.jl/pull/611
[#613]: https://github.com/JuliaWeb/HTTP.jl/pull/613
[#615]: https://github.com/JuliaWeb/HTTP.jl/pull/615
[#616]: https://github.com/JuliaWeb/HTTP.jl/pull/616
[#619]: https://github.com/JuliaWeb/HTTP.jl/pull/619
[#635]: https://github.com/JuliaWeb/HTTP.jl/pull/635
[#636]: https://github.com/JuliaWeb/HTTP.jl/pull/636
[#640]: https://github.com/JuliaWeb/HTTP.jl/pull/640
[#647]: https://github.com/JuliaWeb/HTTP.jl/pull/647
[#648]: https://github.com/JuliaWeb/HTTP.jl/pull/648
[#666]: https://github.com/JuliaWeb/HTTP.jl/pull/666
[#674]: https://github.com/JuliaWeb/HTTP.jl/pull/674
[#675]: https://github.com/JuliaWeb/HTTP.jl/pull/675
[#678]: https://github.com/JuliaWeb/HTTP.jl/pull/678
[#680]: https://github.com/JuliaWeb/HTTP.jl/pull/680
[#682]: https://github.com/JuliaWeb/HTTP.jl/pull/682
[#688]: https://github.com/JuliaWeb/HTTP.jl/pull/688
[#693]: https://github.com/JuliaWeb/HTTP.jl/pull/693
[#701]: https://github.com/JuliaWeb/HTTP.jl/pull/701
[#702]: https://github.com/JuliaWeb/HTTP.jl/pull/702
[#703]: https://github.com/JuliaWeb/HTTP.jl/pull/703
[#704]: https://github.com/JuliaWeb/HTTP.jl/pull/704
[#706]: https://github.com/JuliaWeb/HTTP.jl/pull/706
[#707]: https://github.com/JuliaWeb/HTTP.jl/pull/707
