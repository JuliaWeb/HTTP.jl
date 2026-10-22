# HTTP.jl Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security
- HTTP 2.11.1 requires Reseau 1.6.1 or later, which rejects the eight eMudhra
  CA public keys compromised in October 2026, including cross-signed
  certificates and chains using explicit CA bundles. The check also applies
  when revalidating cached TLS sessions. See the
  [incident report](https://emudhra.we-have-a-problem.com/).

### Added
- The HTTP/1 connection pool now honors a server-advertised
  `Keep-Alive: timeout=<seconds>` response header: the connection is not reused
  once that window (less a one-second safety margin) has elapsed since it went
  idle, whichever of it and `idle_timeout_ns` is tighter, and a hint with no
  headroom (`timeout=1` or less) makes the connection non-reusable. Previously
  a request could be written onto a connection the server had already closed
  at its own keep-alive deadline. ([#1155])
- Added `HTTP2Settings` to configure HTTP/2 receive flow-control windows (per-stream `initial_window_size` and connection-level `connection_window_size`). Pass it via the `http2_settings` keyword on `Client`, `Server`, `listen!`, `serve!`, `serve`, and `connect_h2!`. Defaults preserve the protocol-default 65535-byte windows, and the per-stream receive buffer cap is derived from the window. Raising the windows improves single-stream throughput on links with non-trivial latency.
- Added `HTTP.peeraddr(::HTTP.Stream)`, returning the remote (client) `SocketAddr` of a server stream for both plain-TCP and TLS connections and both HTTP/1 and HTTP/2. This is the supported way to obtain the client IP (for rate limiting, audit logging, and per-client policy) without reaching into transport internals, and restores the capability `Sockets.getpeername(::HTTP.Stream)` provided in HTTP.jl 1.x.
- Added `HTTP.RetrySkippedEvent`, a request trace event emitted when the retry
  policy wanted to retry an attempt but the retry was not armed — because the
  transport's `RetryBucket` denied capacity (`reason = :retry_bucket`) or the
  request deadline preempted the backoff (`reason = :deadline`). Previously a
  denied retry was indistinguishable from a non-retryable failure. ([#1353])
- Added `HTTP.TLSTransportError`, raised when TLS-level I/O fails on an
  established connection during a request. Previously such failures were
  mislabeled `TLSHandshakeError`; that type is now reserved for actual
  connection-setup failures. `HTTP.isrecoverable` classifies both wrappers by
  their underlying cause. ([#1353])
- Added `setheader!`, `appendheader!` and `removeheader!` as the conventional
  mutating-name spellings of `setheader`, `appendheader` and `removeheader`.
  Each pair is the same function (extending one name extends the other), the
  historical names are not deprecated, and all six are `public`. ([#1277])
- Added `llms.txt` and `llms-full.txt` to the documentation site, following the
  [llms.txt](https://llmstxt.org/) convention: a short index of the documentation
  pages, and the full documentation with every docstring expanded, as plain
  markdown for LLM tooling. They are published next to the HTML docs, for
  example at `https://juliaweb.github.io/HTTP.jl/stable/llms.txt` and
  `https://juliaweb.github.io/HTTP.jl/stable/llms-full.txt`. ([#1351])
- Added `HTTP.Handlers.logging_middleware`, an opt-in access-log middleware.
  It wraps a request handler (or a stream handler) and emits one log record
  per request through Julia's logging system with the method, target, response
  status, elapsed milliseconds, the response body length when it is known
  without reading the body, and the client peer address for stream handlers.
  A handler exception is logged at `Logging.Error` and rethrown. This restores
  the request logging that HTTP.jl 1.x offered through `access_log`; the
  middleware is not exported and is off unless a handler is wrapped with it.
  ([#1345])
- Added `max_line_bytes` and `max_header_bytes` keywords to `Transport` so the
  HTTP/1 client's per-line and header-block limits can be tuned per transport
  (`HTTP.Transport(max_line_bytes = 128 * 1024)`). Both must be positive and
  `max_line_bytes` may not exceed `max_header_bytes`. ([#1362])
- Added an `allow_h2c` keyword to `Server`, `listen!`, `serve!` and `serve`.
  With `allow_h2c = false`, plain TCP listeners parse every connection as
  HTTP/1 instead of serving cleartext HTTP/2 (h2c) to clients that open with
  the HTTP/2 preface. The default is unchanged, and TLS listeners still pick
  `h2` through ALPN. ([#1385])

### Changed
- `HTTP.Headers` keeps each header name as the caller spelled it and matches
  names case-insensitively, as HTTP.jl 1.x did. HTTP.jl 2.0 through 2.7
  rewrote every name into `Content-Type` form on insertion, so a request header
  such as `providerId` went out as `Providerid`. That breaks servers that treat
  header names as case-sensitive data, such as Azure Service Bus custom
  message properties. HTTP/1 now sends names as spelled, HTTP/2 still sends
  them in lowercase, and headers received from the network still use
  `Content-Type` form. `canonicalize_headers=true` works again: it sends
  request header names in `Content-Type` form, and no longer logs a
  "has no effect" warning. ([#1377])
- Raised the default HTTP/1 per-line limit (request/status lines and single
  header lines) from 8 KiB to 64 KiB, matching Python's `http.client`. Real
  origins send single header lines longer than 8 KiB — a 9,695-byte
  `Content-Security-Policy` was reported — and HTTP.jl failed such responses
  with `ProtocolError: HTTP/1 line exceeds configured max_line_bytes` while
  curl and Python accepted them. The 1 MiB header-block limit is unchanged and
  still bounds memory; the server-side request parser shares the new per-line
  default. ([#1362])
- After `HTTP.startwrite(stream)`, a fixed-length HTTP/1 stream response is
  sent as it is written once its body passes 4 KiB, so a handler can stream a
  large `Content-Length` body instead of holding all of it until `closewrite`.
  A smaller body still goes out in one write with the head. A response started
  by `write` alone is still held whole, so a handler failure can still get an
  error response. ([#1384])
- `HTTP.streamhandler` streams a response body that is not already in memory,
  such as a `fileserver` file, as `serve!` does, instead of holding all of it
  until the handler finishes. ([#1384])

### Fixed
- `serve!` answers a handler's response that cannot be sent with 500 and logs
  it. Such a response has an unsupported `Transfer-Encoding`, a control
  character in a header value, an invalid header name, reason phrase or
  trailer, or a status code outside 100-999. Before, the connection closed with
  no response and nothing logged. A response body that fails after the head is
  sent is now logged as a handler error, and the body is left unfinished; before,
  it ended the connection task silently. ([#1451])
- The HTTP/2 client handles a `GOAWAY` with an error code, such as
  `ENHANCE_YOUR_CALM`, like one with `NO_ERROR`: streams above
  `last_stream_id` fail with the retryable `H2GoAwayError` and the others keep
  their responses. It failed every stream on the connection. ([#1460])
- `WebSockets.open` raises the error types `HTTP.request` raises, such as
  `ConnectError` for a refused connection, instead of Reseau exceptions such
  as `Reseau.HostResolvers.OpError`. ([#1456])
- A TLS handshake that runs into the connect or request deadline raises
  `TimeoutError` with operation `tls_handshake`, retried like a connect
  timeout, or `request` when the request deadline came first. It raised
  `TLSHandshakeError`, for HTTP/1, HTTP/2, and `wss://` connections. ([#1455])
- Printing a `ProxyConfig`, `Transport`, or `Client` no longer shows
  credentials. The default display showed a proxy's Basic credentials (base64
  of `user:password`) and a SOCKS proxy's password in plain text, a client's
  `default_basicauth` and `default_query` values and jar cookies, and the
  transport's TLS session caches; they now print short summaries. ([#1465])
- A request whose URL path or query holds a control character, such as a tab,
  fails before a connection is made and is not retried. It opened five
  connections first, because the `ParseError` raised when the request line was
  written counts as recoverable; a redirect to such a `Location` did the same.
  ([#1459])
- A cookie whose `Domain` is a public suffix equal to the request host, such
  as `Domain=localhost` from `localhost`, is kept as a host-only cookie, as
  RFC 6265 §5.3 says. It was dropped. ([#1471])
- The HTTP/1 client bounds the informational (1xx) responses it reads before
  the final one: their heads share the transport's `max_header_bytes` budget,
  and past it the request fails with a `ProtocolError`. A server could send
  `103 Early Hints` forever, and `read_idle_timeout` never fired because data
  kept arriving. ([#1476])
- A buffered response body with a `Content-Length` above 1 MiB is read into a
  vector that grows toward the declared length as bytes arrive, so `resp.body`
  is exactly sized. A 10 MiB response allocated 34 MiB in all and kept a 16
  MiB buffer; it now allocates 25 MiB and keeps 10 MiB. ([#1480])
- The `server handler error` log record's `target` leaves out the query
  string, which often carries tokens or signatures. ([#1473])
- A stream handler that fails before its response head is sent always gets an
  error response. The server still sends the error with the handler's headers,
  but when those headers are what failed, such as a NUL in a value, it now
  falls back to a new error response instead of sending nothing. ([#1457])
- `servecontent`, `servefile` and `fileserver` scan `If-Match` and
  `If-None-Match` lists in linear time. A long list, such as several header
  lines joined into one value, cost time and memory quadratic in its length.
  Weak comparison drops only a leading `W/`, and an entity-tag with a byte
  above 0x7F no longer produces a 500. ([#1442])
- `handlertimeout` wakes the waiting request as soon as the handler finishes.
  It polled for the result every millisecond, which added up to 1 ms to each
  request whose handler yields and woke the interactive thread 1000 times a
  second per waiting request. ([#1441])
- `Form` escapes `"`, CR, and LF in multipart field names and file names as
  browsers do (`%22`, `%0D`, `%0A`), and a part content type or transfer
  encoding containing CR or LF throws `ArgumentError`. Such names ended the
  quoted parameter or the header line and changed the parts the receiver
  saw. `parse_multipart_form` and `parse_multipart` read the boundary
  parameter case-insensitively, in any position, and quoted, as .NET's
  `HttpClient` sends it; they matched only `multipart/...; boundary=X`. ([#1444])
- The HTTP and WebSocket servers keep accepting connections after an OS error
  from `accept`, such as running out of file descriptors (`EMFILE`). The error
  is logged and accept is retried after a wait that grows from 5 ms to 1 s.
  Previously the accept loop ended, with nothing logged, and the server
  stopped accepting connections for good. ([#1443])
- A WebSocket server rejects an unmasked frame, and a client a masked one, as
  soon as it reads the frame header (RFC 6455 §5.1). Previously the frame was
  delivered to the handler first and the connection was closed after it.
  ([#1445])
- `serve!` sends `100 Continue` before it reads a request body when the
  request has `Expect: 100-continue`. Previously it never did, so such a client
  waited for its own timeout (1 s for HTTP.jl and curl) before sending the
  body. A body whose `Content-Length` is over `max_body_bytes` still gets 413
  without the interim response. ([#1446])
- The HTTP/2 server returns flow-control credit for every request byte it
  drops: DATA padding, request bytes a handler leaves unread, and DATA for a
  reset stream. That credit was lost, so a connection's receive window shrank
  until uploads on it stalled. A handler that answered before the request body
  ended left its stream counted against `max_concurrent_streams`, so later
  streams were refused and `close(server)` waited forever; the stream is now
  removed once its handler finishes. DATA beyond the advertised connection
  window is a connection error instead of being buffered. ([#1452])
- The client matches and stores cookie paths without the request's query, as
  RFC 6265 §5.1.4 specifies. A `Path=/a` cookie was not sent to `/a?x=1`, and
  a cookie set by `/d/e?next=/f/g` got the default path `/d/e?next=/f`
  instead of `/d`. ([#1448])
- An HTTP/1 upload that the server answers early and then closes, such as a
  `413` sent after the request head, returns the server's response. The
  client closed the connection when the upload's write failed, so it usually
  raised a broken-pipe, connection-reset, or `TLSTransportError` instead. A
  `write_idle_timeout` during an upload raises `TimeoutError` (it raised
  `NetClosingError`, or `TLSTransportError` over https) and is not retried,
  like a read timeout. ([#1449])
- URLs are checked against RFC 3986 before a connection is made. A userinfo or
  host with a backslash, a space, or a control character, a host with `%`
  (hosts are not percent-decoded), a bracketed host that is not an IPv6
  address, or a `URI` whose path does not start with `/` raises
  `ArgumentError`; a redirect to such a location raises `ProtocolError`.
  Special characters in URL credentials must be percent-encoded, such as a
  Windows `DOMAIN\user` name as `DOMAIN%5Cuser`; a proxy environment variable
  that does not parse is skipped with a warning. `URI` schemes match
  case-insensitively, and URL parse errors leave out the userinfo. ([#1447])
- The HTTP/1 connection pool no longer hands out an idle connection the
  server has already closed. Servers such as MinIO and many Go services close
  idle keep-alive connections without a `Keep-Alive` hint; the pool now peeks
  the socket without waiting before reuse and discards a connection that is at
  end-of-stream or holds unsolicited bytes. Previously a non-idempotent request
  such as a POST failed with `unexpected EOF while reading HTTP/1 data`,
  because it cannot be retried on a dead reused connection.
- `HTTP.streamhandler` closes a streaming response body that a HEAD, 204, or
  304 response does not send, instead of reading it to the end. A HEAD request
  to a server-sent events route kept the event producer running and blocked
  `close(server)`. ([#1409])
- A failed HTTP/2 request no longer closes the pooled connection it shares
  with other requests. A request timeout, a stream reset by the server, a
  request rejected by GOAWAY, or an error from the request body resets only
  that request's stream, and a connection draining after GOAWAY finishes its
  streams before it closes. A request that gets no reply at all still moves
  later requests to a new connection. ([#1426])
- `examples/batch_server_example.jl` answers batch requests again. It called an
  internal function with an outdated signature, so every request got `500`. ([#1435])
- The HTTP/1 server answers any exception a handler throws with
  `500 Internal Server Error` and logs it at `Error` level with the request
  method, target, and client address. A `ProtocolError`, `ParseError`, or
  timeout thrown by a handler, or an invalid `Content-Length` set by a stream
  handler, got `400` or `408` and no log. Errors reading the request body keep
  their `4xx` status, and peer disconnects are not logged. ([#1425])
- `servecontent` (and so `servefile` and `fileserver`) sends the whole content
  with `200` for a `Range` it does not support, as RFC 9110 §14.2 allows: an
  unknown unit such as `items=0-4`, several ranges, or a `Range` on a method
  other than `GET` or `HEAD`. The first two got `416`, and a `POST` got `206`. ([#1433])
- The HTTP/1 server and `streamhandler` no longer modify the `Response` a
  handler returns, so one response object can answer many requests at once.
  Under concurrent HEAD and GET requests, a shared response could send its body
  to a HEAD request and drop it from a GET, and after one failed write on the
  `streamhandler` path every later response carried `Connection: close`. ([#1424])
- `listen!` reports a port that is already in use with `AddressInUseError`, as
  `serve!` does, instead of a `TaskFailedException`. ([#1432])
- An empty request body (`EmptyBody`, what a `GET` handler gets) supports the
  same collection functions as a buffered one: `isempty(req.body)`,
  `length`, `copy`, `collect`, and `Vector{UInt8}(req.body)` work instead of
  throwing a `MethodError`. ([#1434])
- Failed HTTP/1 responses no longer look complete. A stream handler that throws
  after its chunked body started gets no terminating chunk; the connection
  closes, so the client sees an incomplete body. A request handler's response
  whose `String`, byte-vector, or missing body does not match its
  `Content-Length` gets `500 Internal Server Error` before anything is sent,
  instead of a head without the body. `logging_middleware` finishes a stream
  handler's response before logging it, so a body shorter than its
  `Content-Length` is logged as the `500` the client gets, not `200`. ([#1436])
- HTTP/1 status lines name only `HTTP/1.1`, or `HTTP/1.0` for an HTTP/1.0
  response. A stream handler or `servecontent` answered an `HTTP/1.2` request
  with `HTTP/1.2 200 OK`; Go answers `HTTP/1.1`. ([#1431])
- An HTTP/2 server connection no longer stalls when the client sends PING or
  SETTINGS while a `String` or byte-vector response waits for flow-control
  credit. The response kept the connection's write lock while it waited, so
  the server could not answer and never read the WINDOW_UPDATE that followed.
  ([#1410])
- `request_timeout` and `cancel!` end an HTTP/2 request that waits for a free
  stream slot on a connection at the server's `SETTINGS_MAX_CONCURRENT_STREAMS`
  limit. The request waited until a slot freed up, forever with a limit of 0.
  ([#1427])
- HTTP/1 servers answer a request head or body read timeout on a TLS
  connection with `408 Request Timeout`, as on plain TCP. A head timeout
  closed the connection without a response, and a body timeout answered
  `500`. ([#1403])
- When the HTTP/2 server cannot send a response, for example because its
  headers exceed the client's `SETTINGS_MAX_HEADER_LIST_SIZE`, it resets the
  stream with RST_STREAM(INTERNAL_ERROR) and logs the error. The client waited
  for the response forever. ([#1428])
- HTTP/2 header blocks over 16 KiB are sent when the peer's
  `SETTINGS_MAX_FRAME_SIZE` allows larger frames, as Go's HTTP/2 server and
  client do (1 MiB). A client request threw
  `HTTP/2 frame exceeds max_frame_size` and closed its connection, and the
  server never sent the response. ([#1411])
- `close(server)` lets the HTTP/2 streams its GOAWAY covered finish. Any frame
  the client sent after the GOAWAY, such as the WINDOW_UPDATE a large response
  needs, closed the connection mid-response. Streams opened after the GOAWAY
  are refused with REFUSED_STREAM. ([#1429])
- Client URLs: a non-ASCII host (`http://日本/p`) no longer throws
  `StringIndexError`, an empty port (`http://host:/`) means the default port,
  and an empty host (`http://:8080/`) is rejected instead of dialing the local
  machine. A redirect `Location` without a valid host, such as `//:` or
  `http:g`, throws a `ProtocolError` that names it. ([#1400])
- `HTTP.isrecoverable` returns `true` for the `ConnectError` of a refused
  connection and for a `TimeoutError` from a connect or TLS handshake timeout,
  as the built-in retry rules retry their causes. It returned `false`, so a
  retry loop around `HTTP.request` gave up on these transient failures.
  ([#1412])
- HTTP/2 `String` and byte-vector responses send their headers before waiting
  for flow-control credit, as other bodies do. With no credit yet, the headers
  waited for a WINDOW_UPDATE, so a client that waits for the headers before
  granting credit never got a response. ([#1430])
- `HTTP.sniff`, and `servecontent` without a `content_type`, now compile under
  `juliac --trim=safe`. Content sniffing no longer dispatches at runtime.
- Servers compiled with `juliac --trim=safe` verify when they close gracefully
  with `close(server)`, serve byte ranges with `servecontent`, answer HTTP/2
  requests with an error status, or send server-sent events (on Julia 1.14,
  where multi-argument `write` is not specialized on its arguments).
  ([#1399], [#1401], [#1423])
- A stream handler that writes more or fewer bytes than its declared
  `Content-Length` is answered with `500 Internal Server Error` instead of
  `400 Bad Request` while the HTTP/1 response head is still held. ([#1404])
- Requests with a zero-length streaming body can be copied for retries and
  redirects. The first send retains and closes the producer; later sends replay
  the empty payload without trying to clone the producer.
- `expect_continue_timeout` sets how long an HTTP/1 request with `Expect:
  100-continue` waits for `100 Continue` before it sends the body, and `0` sends
  it at once. The keyword was ignored, and the client always waited up to one
  second. ([#1413])
- The HTTP/1 server answers a request line whose HTTP major version is not 1,
  such as `HTTP/2.0` or `HTTP/0.9`, with `505 HTTP Version Not Supported`, as
  Go's server does. It served those requests, and a stream handler's status
  line repeated the request's version. ([#1405])
- Requests to `localhost` and loopback addresses never use proxies from the
  environment, as in Go and HTTP.jl 1.x. With `HTTP_PROXY` set and `NO_PROXY`
  unset, they went through the proxy. ([#1414])
- Fixed-length HTTP/1 streaming bodies reuse one bounded buffer across reads,
  reducing allocation for both uploads and response serialization. Short reads
  no longer allocate a new buffer each time.
- A space in a request URL, a `query` string, or a redirect `Location` is sent
  as `%20`. It went into the request line as is, so `HTTP.get("http://h/a b")`
  sent the invalid `GET /a b HTTP/1.1`. ([#1415])
- `read_header_timeout` limits the first request head on a plain TCP connection
  to one budget, as with `allow_h2c = false`. The cleartext HTTP/2 preface check
  restarted the budget when the first bytes arrived, so a slow client could take
  nearly twice the limit. ([#1406])
- A client read timeout over HTTPS with HTTP/1 raises `TimeoutError`, as over
  plain HTTP. It raised `TLSTransportError`. ([#1416])
- Fixed an HTTP/1 upload hang in trimmed executables on Julia 1.13. Request-header
  waits also propagate failed writer tasks instead of waiting indefinitely.
  ([#1390])
- The default `User-Agent` header and `HTTP.VERSION` give the installed HTTP.jl
  version. They always said 2.0.0. ([#1417])
- A byte-buffer `response_stream` receives only a 2xx body. A redirect that is
  not followed, such as S3's 301 for the wrong region (it has no `Location`),
  went into the buffer, and a body larger than the buffer raised `ArgumentError:
  Unable to grow response stream` instead of returning the 301. A body kept out
  of the buffer is read up to 1 MiB, or `max_decompressed_size` if smaller; it
  was read in full, however large. ([#1407])
- Each ignored HTTP.jl 1.x client keyword, such as `pool`, `retry_delays`, or
  `sslconfig`, warns once. Only the first one passed in a session warned.
  ([#1418])
- An empty `write` to a server stream (`write(stream, UInt8[])`, an empty
  `codeunits` or view) is now a no-op. On a chunked HTTP/1 response it was
  framed as a zero-length chunk, the last-chunk marker, so the client saw the
  body end early and later writes went out after the terminator.
- `HTTP.WebSockets.open` closes the client it creates for
  `require_ssl_verification = false` when the handshake fails, for example on a
  redirect to an invalid `Location`, and closes the connection when the server's
  first frame is invalid. Both stayed open. ([#1419])
- HTTP and WebSocket client redirects resolve `Location` against the current
  URL as RFC 3986 §5.2 specifies. A relative location lost repeated slashes
  (`d//e` requested `d/e`), `?` dropped the empty query, `?q=1#top` sent the
  fragment to the server, and absolute and `//host` locations kept their `.`
  and `..` segments.
- A URL port must be 1-65535 in decimal digits, or the URL is rejected with an
  `ArgumentError` when it is parsed. `http://a:abc/` failed later with a
  confusing message, and `http://a:+80/` connected to port 80. The HTTP/1 server
  answers an absolute-form request target with such a port with `400`. ([#1420])
- A byte-buffer `response_stream` (a vector or view) is left untouched when the
  status is 300 or above, other than a 301, 302, 303, 307, or 308 redirect. The
  body goes to `response.body`, as in HTTP.jl 1.x, so an error body larger than
  the buffer raises `StatusError` rather than `ArgumentError: Unable to grow
  response stream`. `IO` sinks still receive every final response body.
- Cookie handling no longer throws `StringIndexError` on non-ASCII text. A
  request to a path such as `/日本/a` threw when the response set a cookie, as did
  a cookie name or quoted value that ended in a non-ASCII character. ([#1421])
- HTTP/1 server read deadlines now follow the request phase. `read_header_timeout`
  no longer limits the request body (only `read_timeout` does) or the wait
  between keep-alive requests (`idle_timeout`, else `read_timeout`), so a server
  that sets only `read_header_timeout` keeps idle connections open. An idle
  timeout or client close between requests no longer writes a `408` or `400`.
  ([#1381])
- `HTTP.getcookies(req)` returns the cookies in the request's `Cookie` header.
  It returned an empty vector unless the non-public `cookie_middleware` had run
  first. ([#1422])
- HTTP/1 stream handlers no longer send `100 Continue` after the response head.
  A handler that called `startwrite` before reading the body of an
  `Expect: 100-continue` request put the interim response inside its own
  response body.
- The HTTP/2 client and server copy received trailers in one pass. They
  copied them name by name and rescanned the whole trailer block for each
  name, so a peer could cost seconds to minutes of CPU per stream by sending
  many distinct trailer names (16k names took about 0.9 s). A repeated
  trailer name that is not adjacent now stays a separate entry, as over
  HTTP/1, instead of being joined with commas.
- The HTTP/2 server now ends a request only after a trailer block that spans
  CONTINUATION frames is complete. It ended the request at the HEADERS frame
  carrying END_STREAM, so the handler could run and see no trailers.
- `show` and `print` on a `Request` now show the `Host` line the HTTP/1
  writer sends: one line, first, with the same value. A request with both a
  caller `Host` header and `request.host` showed no `Host` line although the
  caller's value was sent, and a stored `Host` was shown in its stored
  position instead of first. `verbose = 2` output uses this display.
- The HTTP/2 client now returns connection-level flow-control credit for
  response bytes it received but never read: when a body is closed unread
  (including every attempt the built-in retry loop gives up on), when the
  request fails before its response body is handed out (for example a peer
  reset while the request body is still uploading), when DATA arrives for a
  stream that was already reset, and for DATA frame padding.
  Previously each such body permanently shrank the shared 65535-byte
  connection window, and once it hit zero every later response on that
  connection stalled until a timeout or a peer reset. Polling an endpoint that
  answers `5xx` for a while was enough to trigger it. ([#1371])
- `Response` objects built from a `String` body can now be sent repeatedly:
  the string is stored as-is instead of being wrapped in a single-use
  `BytesBody`, matching `Vector{UInt8}` bodies, so "baked" responses work on
  the request-handler, stream-handler and HTTP/2 paths. Returning a response
  whose built-in `BytesBody` or `CallbackBody` was already sent now fails
  before the head is written and the server answers `500`, instead of emitting
  a truncated body. Bodyless responses remain valid. ([#1333])
- The HTTP/1.1 client now writes `Host` as the first header field line after
  the request line, as RFC 9112 §3.2 recommends and as curl, Go and Python do.
  It used to be appended after every caller-supplied and client-default header
  (`User-Agent`, `Accept-Encoding`, ...), which some CDN front ends reject with
  403 for an otherwise identical request. A caller-supplied `Host` header is
  moved to the front rather than kept in place, and exactly one `Host` line is
  written; `Request.headers` itself is not reordered. ([#1361])
- Restored HTTP and WebSocket server task scheduling to Julia's `:interactive`
  thread pool so default-pool compute work cannot starve server and health-check
  tasks when an interactive thread is configured. ([#1342])
- Percent-decode `userinfo` before building the `Basic` auth header (RFC 3986); fixes wrong credentials for request URLs and proxies containing percent-encoded characters.
- Fixed the client retry budget (`RetryBucket`) treating a successful retried
  attempt as a full-cost failure. The per-host budget drained by 10 of 500
  units on every retry — even one that recovered with a 2xx — and never
  refilled, so after ~50 retries against a host every subsequent retry was
  silently denied for the transport's lifetime and transient errors surfaced
  raw despite `retry=true`. A retry reservation is now settled by the
  effective retry decision for the response it produced: refunded in full when
  the built-in policy (or a custom `retry_if`) no longer wants a retry, and
  keeping the partial cost when the response is still classified as a failure.
  On the final attempt the built-in classification applies without invoking
  `retry_if`, and a retry that `retry_if` explicitly requested conservatively
  keeps cost on a non-2xx/3xx outcome. Each successful non-retried request
  restores one unit of previously consumed budget, retry reservations and
  response connections are released even when a trace or retry-policy callback
  throws, and the request deadline is rechecked after the backoff sleep.
  ([#1353])
- The HTTP/1 transport now retries a replayable idempotent request for as long
  as failures land on *reused* pooled connections. It tries at most
  `max_idle_per_host` reused connections, then forces a fresh dial instead of
  accepting another concurrent pool return. PUT and DELETE receive the same
  stale-connection recovery as the other idempotent methods.
  Pooled connections can be discarded by the peer in correlated batches, in
  which case the single retry would draw the next equally-dead pooled
  connection and fail. ([#1353])
- Dead reused TLS connections that fail with `Reseau.TLS.TLSError` (for
  example an RST surfacing as a wrapped `SystemError` or a truncated TLS record
  reported as `unexpected EOF`) are now classified by their public error shape
  in the transport's reused-connection retry. HTTP/2 read-loop wrappers also
  preserve this classification. ([#1353])
- The HTTP/2 client now skips informational (1xx) response header blocks such
  as `103 Early Hints` and keeps waiting for the final response head, matching
  the HTTP/1 client. Previously the first header block became the response
  regardless of its `:status`, so the real head was treated as trailers and
  the request failed with `HTTP/2 response trailers must end the stream`. A
  1xx block carrying END_STREAM, a `101 Switching Protocols` block (not
  supported by HTTP/2), and a DATA frame arriving before the final head are
  rejected as protocol errors. END_STREAM on a HEADERS frame whose block ends
  on a CONTINUATION frame is now applied once the block completes, so trailers
  split across frames are no longer rejected. ([#1360])
- `addcookie!(::Request, ::Cookie)` now keeps every request cookie in a single
  `Cookie` header with the pairs separated by `"; "`. It went through
  `appendheader`, which merges a repeated header into the previous entry with a
  comma, so two adjacent calls produced `Cookie: a=1,b=2`. `cookies(::Request)`
  splits a `Cookie` header on `;` only, so that header parsed back as the single
  cookie `a="1,b=2"` and the second cookie was lost.
- The HTTP/1 parser now joins every `Cookie` line of a request into one
  `Cookie` header with `"; "`, as the HTTP/2 server does. Adjacent lines were
  joined with a comma, so `Cookie: a=1` followed by `Cookie: b=2` was read by
  `cookies(::Request)` as the single cookie `a="1,b=2"`. ([#1386])
- `appendheader` now joins repeated `Cookie` values with `"; "` instead of a
  comma, so `HTTP.get(url, ["Cookie" => "a=1", "Cookie" => "b=2"])` sends
  `Cookie: a=1; b=2` rather than the single cookie `a="1,b=2"`. ([#1386])
- Received header sections are joined in linear time. Joining each repeated
  line onto the previous one rebuilt the growing value, so an HTTP/1 request
  made of 1 MiB of repeated header lines took about 3 s and 16 GiB of
  allocation to parse; HTTP/2 request and response headers scaled the same
  way. ([#1386])

## [v2.0.0] - 2026-04-27
HTTP.jl 2.0 is a major rewrite of the package internals and public API. The
release keeps the familiar `HTTP.request`, verb helpers, `HTTP.serve`, routing,
WebSocket, and SSE workflows, but rebuilds them on a smaller, explicit core
that delegates transport mechanics to
[`Reseau.jl`](https://github.com/JuliaServices/Reseau.jl). The 2.0 line is the
new foundation for HTTP/1.1, HTTP/2, timeouts, streaming, precompilation, and
future protocol work.

### Added
- Added a new core API around `Request`, `Response`, `Headers`,
  `RequestContext`, explicit request/response body types, and structured
  timeout configuration.
- Added `Client` and `Transport` objects for reusable client configuration,
  connection reuse, cookie jars, redirect limits, retry policy, default
  headers, and HTTP/2 preference.
- Added first-class HTTP/2 client and server support through the Reseau-backed
  transport layer, including stream lifecycle handling, flow-control-aware
  body reads, and h2c prior-knowledge support for local/plaintext use cases.
- Added structured timeout phases for connection establishment, complete
  request deadlines, response-header waits, read-idle waits, write-idle waits,
  and `Expect: 100-continue` waits.
- Added `HTTP.HTTPTimeoutError` as the public timeout exception alias and
  richer timeout messages for client and server failures.
- Added `HTTP.open` for response streaming with the same request pipeline as
  `HTTP.request`.
- Added request tracing support through trace callbacks, client event types,
  and the `verbose` request keyword.
- Added server helpers for streaming handlers, static content, file serving,
  file-server roots, graceful shutdown callbacks, handler timeouts, and
  socket-close control.
- Added Server-Sent Events support for clients and servers through
  `SSEEvent`, `sse_stream`, and the `sse_callback` request keyword.
- Added WebSocket client/server support under `HTTP.WebSockets`, including
  `HTTP.WebSockets.open`, `HTTP.WebSockets.listen`, and
  `HTTP.WebSockets.listen!`.
- Added precompile workloads that cover common client, server, router, SSE,
  WebSocket, and streaming paths.
- Added curated manual and API-reference documentation for the 2.0 public
  surface, plus a migration guide for common 1.x call patterns.

### Changed
- The package now presents a curated 2.0 public API built around `Request`,
  `Response`, `Stream`, `Client`, `Transport`, and explicit body types on top
  of `Reseau`.
- Julia 1.10 is now the minimum supported Julia version.
- `HTTP.request` and the verb helpers now return a fully materialized
  `Response.body::Vector{UInt8}` by default. Use `HTTP.open` or the
  `response_stream` keyword when you need streaming control.
- `Request` and `Response` constructors now prefer explicit keyword-oriented
  forms. Common 1.x positional constructor forms remain accepted as migration
  shims, but new code should use `Request(method, target; ...)` and
  `Response(status; headers=..., body=...)`.
- `Response.status_code` has been renamed to `Response.status`.
- `RequestContext` is now a typed request state object with cancellation,
  deadline, metadata, and timeout fields. Dict-like metadata access is
  preserved for migration, but new code should treat it as request state rather
  than as a plain `Dict{Symbol,Any}`.
- Client retry configuration now centers on `retry`, `retries`, `retry_if`,
  `respect_retry_after`, and `retry_bucket` instead of the 1.x
  `retry_delays` / `retry_check` pair.
- Client timeout keywords now use explicit phase names. In particular,
  `readtimeout` is replaced by `read_idle_timeout`; request-wide deadlines
  should use `request_timeout`.
- Connection pooling is now owned by `Client` / `Transport` instead of the 1.x
  `pool` keyword and layer stack.
- TLS and socket behavior are now configured through the Reseau transport layer
  instead of the 1.x `sslconfig` / `socket_type_tls` extension points.
- Routing helpers are documented as part of the `HTTP.Handlers` surface, while
  the high-level server APIs continue to accept ordinary Julia functions,
  router objects, middleware, and stream handlers.
- WebSocket entrypoints now live under `HTTP.WebSockets`; use
  `HTTP.WebSockets.open`, `HTTP.WebSockets.listen`, and
  `HTTP.WebSockets.listen!` for WebSocket-specific behavior.
- The documentation now explicitly calls out intentionally deferred Go-parity
  areas for the 2.x release line, including HTTP/2 server push, `Pusher`,
  `ResponseController` / hijack-style control APIs, fuller `httptrace`
  coverage, and full `net/url` / `ServeMux` parity.

### Deprecated
- `readtimeout` remains accepted as a migration alias for `read_idle_timeout`.
- Several 1.x client keywords remain accepted for compatibility but are either
  mapped to the new API or ignored with migration warnings when there is no
  direct 2.0 equivalent: `pool`, `retry_delays`, `retry_check`, `sslconfig`,
  `socket_type_tls`, `copyheaders`, `canonicalize_headers`,
  `detect_content_type`, `logerrors`, `logtag`, and `observelayers`.
- Treating `RequestContext` as a plain dictionary is deprecated in favor of the
  typed fields and metadata helpers.

### Removed
- Undocumented 1.x internals are no longer supported migration targets for the
  2.0 line.
- The old layer-stack internals, connection-pool internals, HPACK internals,
  parser internals, and low-level HTTP/2 implementation details are no longer
  documented public API.
- The package no longer carries a source override for Reseau; release builds
  resolve the registered `Reseau = "1"` dependency.

### Fixed
- Hardened HTTP/1.1 and HTTP/2 server behavior around request-body streaming,
  content-length accounting, invalid header handling, timeout cleanup,
  connection teardown, and stream cancellation.
- Hardened client-side redirect, retry, proxy, cookie, timeout, and streaming
  paths against the new transport abstraction.
- Improved docs coverage so exported APIs and documented submodule APIs are
  covered by the Documenter build.
- Skipped the package precompile workload when Julia is running with coverage
  instrumentation, keeping CI focused on tests while preserving normal package
  precompilation for users.

## [v1.11.0] - 2025-12-20
### Added
- Added full Server-Sent Events (SSE) support for both client and server:
  - **Client-side**: `sse_callback` keyword argument for `HTTP.request` to parse SSE streams on
    successful responses, invoking a callback with `HTTP.SSEEvent` for each event received.
  - **Server-side**: `HTTP.sse_stream(200) do stream ... end` helper to write
    `HTTP.SSEEvent`s and automatically close the stream when the block finishes (or use
    `response = HTTP.sse_stream(200)` for manual management).
  - `HTTP.SSEEvent` struct for representing SSE events with `data`, `event`, `id`, and `retry` fields.

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


[Unreleased]: https://github.com/JuliaWeb/HTTP.jl/compare/v2.0.0...HEAD
[v2.0.0]: https://github.com/JuliaWeb/HTTP.jl/compare/v1.11.0...v2.0.0
[v1.11.0]: https://github.com/JuliaWeb/HTTP.jl/releases/tag/v1.11.0


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
[#1277]: https://github.com/JuliaWeb/HTTP.jl/issues/1277
[#1333]: https://github.com/JuliaWeb/HTTP.jl/issues/1333
[#1342]: https://github.com/JuliaWeb/HTTP.jl/issues/1342
[#1155]: https://github.com/JuliaWeb/HTTP.jl/issues/1155
[#1351]: https://github.com/JuliaWeb/HTTP.jl/issues/1351
[#1345]: https://github.com/JuliaWeb/HTTP.jl/issues/1345
[#1353]: https://github.com/JuliaWeb/HTTP.jl/issues/1353
[#1360]: https://github.com/JuliaWeb/HTTP.jl/issues/1360
[#1361]: https://github.com/JuliaWeb/HTTP.jl/issues/1361
[#1362]: https://github.com/JuliaWeb/HTTP.jl/issues/1362
[#1371]: https://github.com/JuliaWeb/HTTP.jl/issues/1371
[#1377]: https://github.com/JuliaWeb/HTTP.jl/issues/1377
[#1381]: https://github.com/JuliaWeb/HTTP.jl/issues/1381
[#1384]: https://github.com/JuliaWeb/HTTP.jl/issues/1384
[#1385]: https://github.com/JuliaWeb/HTTP.jl/issues/1385
[#1386]: https://github.com/JuliaWeb/HTTP.jl/issues/1386
[#1390]: https://github.com/JuliaWeb/HTTP.jl/issues/1390
[#1399]: https://github.com/JuliaWeb/HTTP.jl/issues/1399
[#1400]: https://github.com/JuliaWeb/HTTP.jl/issues/1400
[#1401]: https://github.com/JuliaWeb/HTTP.jl/issues/1401
[#1403]: https://github.com/JuliaWeb/HTTP.jl/issues/1403
[#1404]: https://github.com/JuliaWeb/HTTP.jl/issues/1404
[#1405]: https://github.com/JuliaWeb/HTTP.jl/issues/1405
[#1406]: https://github.com/JuliaWeb/HTTP.jl/issues/1406
[#1407]: https://github.com/JuliaWeb/HTTP.jl/issues/1407
[#1409]: https://github.com/JuliaWeb/HTTP.jl/issues/1409
[#1410]: https://github.com/JuliaWeb/HTTP.jl/issues/1410
[#1411]: https://github.com/JuliaWeb/HTTP.jl/issues/1411
[#1412]: https://github.com/JuliaWeb/HTTP.jl/issues/1412
[#1413]: https://github.com/JuliaWeb/HTTP.jl/issues/1413
[#1414]: https://github.com/JuliaWeb/HTTP.jl/issues/1414
[#1415]: https://github.com/JuliaWeb/HTTP.jl/issues/1415
[#1416]: https://github.com/JuliaWeb/HTTP.jl/issues/1416
[#1417]: https://github.com/JuliaWeb/HTTP.jl/issues/1417
[#1418]: https://github.com/JuliaWeb/HTTP.jl/issues/1418
[#1419]: https://github.com/JuliaWeb/HTTP.jl/issues/1419
[#1420]: https://github.com/JuliaWeb/HTTP.jl/issues/1420
[#1421]: https://github.com/JuliaWeb/HTTP.jl/issues/1421
[#1422]: https://github.com/JuliaWeb/HTTP.jl/issues/1422
[#1423]: https://github.com/JuliaWeb/HTTP.jl/issues/1423
[#1424]: https://github.com/JuliaWeb/HTTP.jl/issues/1424
[#1425]: https://github.com/JuliaWeb/HTTP.jl/issues/1425
[#1426]: https://github.com/JuliaWeb/HTTP.jl/issues/1426
[#1427]: https://github.com/JuliaWeb/HTTP.jl/issues/1427
[#1428]: https://github.com/JuliaWeb/HTTP.jl/issues/1428
[#1429]: https://github.com/JuliaWeb/HTTP.jl/issues/1429
[#1430]: https://github.com/JuliaWeb/HTTP.jl/issues/1430
[#1431]: https://github.com/JuliaWeb/HTTP.jl/issues/1431
[#1432]: https://github.com/JuliaWeb/HTTP.jl/issues/1432
[#1433]: https://github.com/JuliaWeb/HTTP.jl/issues/1433
[#1434]: https://github.com/JuliaWeb/HTTP.jl/issues/1434
[#1435]: https://github.com/JuliaWeb/HTTP.jl/issues/1435
[#1436]: https://github.com/JuliaWeb/HTTP.jl/issues/1436
[#1441]: https://github.com/JuliaWeb/HTTP.jl/issues/1441
[#1442]: https://github.com/JuliaWeb/HTTP.jl/issues/1442
[#1443]: https://github.com/JuliaWeb/HTTP.jl/issues/1443
[#1444]: https://github.com/JuliaWeb/HTTP.jl/issues/1444
[#1445]: https://github.com/JuliaWeb/HTTP.jl/issues/1445
[#1446]: https://github.com/JuliaWeb/HTTP.jl/issues/1446
[#1447]: https://github.com/JuliaWeb/HTTP.jl/issues/1447
[#1448]: https://github.com/JuliaWeb/HTTP.jl/issues/1448
[#1449]: https://github.com/JuliaWeb/HTTP.jl/issues/1449
[#1451]: https://github.com/JuliaWeb/HTTP.jl/issues/1451
[#1452]: https://github.com/JuliaWeb/HTTP.jl/issues/1452
[#1455]: https://github.com/JuliaWeb/HTTP.jl/issues/1455
[#1456]: https://github.com/JuliaWeb/HTTP.jl/issues/1456
[#1457]: https://github.com/JuliaWeb/HTTP.jl/issues/1457
[#1459]: https://github.com/JuliaWeb/HTTP.jl/issues/1459
[#1460]: https://github.com/JuliaWeb/HTTP.jl/issues/1460
[#1465]: https://github.com/JuliaWeb/HTTP.jl/issues/1465
[#1471]: https://github.com/JuliaWeb/HTTP.jl/issues/1471
[#1473]: https://github.com/JuliaWeb/HTTP.jl/issues/1473
[#1476]: https://github.com/JuliaWeb/HTTP.jl/issues/1476
[#1480]: https://github.com/JuliaWeb/HTTP.jl/issues/1480
