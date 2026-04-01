# Action Items: HTTP 2.0 Hardening Pass

## Context
- Repo: HTTP
- Worktree: /Users/jacob.quinn/.julia/dev/HTTP
- Branch: codex/http-2.0-extraction
- Reference baseline: `/Users/jacob.quinn/golang/src/net/http`, bundled `h2_bundle.go`, and `/Users/jacob.quinn/golang/src/vendor/golang.org/x/net/http2/hpack/*.go`
- Existing local edits present during planning: `src/http1.jl`, `src/http2_client.jl`, `src/http_transport.jl`
- Scope for this document: convert the completed review findings into an execution-ready, prioritized hardening plan only; no implementation work has started yet

## Items

### [x] ITEM-001 (P0) Fix shared header container semantics so they match Go-style multi-value behavior
- Description: The `Headers` container currently behaves incorrectly for repeated non-adjacent headers. `setheader` only overwrites the first copy, `removeheader` only deletes the first copy, and `headercontains` returns after inspecting only the first matching header line. That breaks `Connection`, `Transfer-Encoding`, redirect stripping, and any call site that assumes the Go `Header` API semantics of all-values lookup and all-values replacement/deletion.
- Desired outcome: Header mutation and lookup semantics are deterministic, safe, and parity-aligned with Go for repeated header fields regardless of insertion order.
- Affected files: `src/http_core.jl`, `src/http1.jl`, `src/http_client_redirect.jl`, `src/http_client.jl`, `src/http_server.jl`, `src/http_websockets.jl`, `test/http_core_tests.jl`, `test/http1_wire_tests.jl`, `test/http_client_tests.jl`, `test/http_server_http1_tests.jl`
- Implementation notes:
  - Redefine the contract for `setheader`, `appendheader`, `removeheader`, `header`, `headers`, and `headercontains` so repeated fields are handled intentionally instead of incidentally.
  - Decide whether the internal representation should remain ordered pairs or move toward a more explicit "ordered multi-value" structure; if the pair-vector stays, add helper paths that operate over all matching entries, not only the first.
  - Ensure `removeheader` removes every stored instance of the key, not just the first one.
  - Ensure `setheader` leaves exactly one logical value for the key unless a multi-value header is intentionally being preserved.
  - Ensure `headercontains` scans all stored field instances and all comma-separated list members.
  - Audit redirect sanitization, server response normalization, websocket handshake normalization, and HTTP/1 connection-close logic after the container behavior changes.
- Verification:
  - `julia --project=. test/runtests.jl`
  - Add focused assertions covering non-adjacent duplicate `Connection`, `Transfer-Encoding`, `Cookie`, and `Set-Cookie` entries.
  - Add a regression reproducer proving that `headercontains` sees a later `Connection: close` header when an earlier `Connection` line is present.
- Assumptions:
  - Preserving header insertion order is still required for compatibility with existing APIs and tests.
  - `Set-Cookie` must remain non-merged even if other repeated headers are normalized.
  - Execution assumption for implementation: keep `Headers.entries::Vector{Pair{String,String}}` as the storage model and harden the helper semantics around it instead of redesigning the container in this pass.
- Risks:
  - Changing shared header semantics can ripple into many higher-level call sites and snapshot-style tests.
  - Existing tests may implicitly depend on the current "first header wins" behavior.
- Completion criteria:
  - All header mutation and lookup helpers behave correctly for repeated non-adjacent fields.
  - Redirect/header-stripping and connection-close decisions no longer leave shadow duplicates behind.
  - New regression tests cover the exact failure modes found in review.
- Verification evidence:
  - `julia --project=. test/http_core_tests.jl`
  - `julia --project=. test/http_client_tests.jl`
  - `julia --project=. test/http_integration_tests.jl`
  - `julia --project=. test/runtests.jl`

### [x] ITEM-002 (P0) Harden outgoing HTTP/1 header and trailer serialization against injection and invalid syntax
- Description: HTTP/1 serialization currently writes header names and values verbatim. That permits CRLF injection, response splitting, and invalid header tokens to reach the wire. Trailer declarations are also not validated against forbidden keys like `Content-Length`, `Transfer-Encoding`, and `Trailer`.
- Desired outcome: Outgoing HTTP/1 requests and responses sanitize or reject invalid header names and values exactly enough to remove header injection and malformed trailer risks, closely matching Go's hardened behavior.
- Affected files: `src/http1.jl`, `src/http_core.jl`, `test/http1_wire_tests.jl`, `test/http_client_transport_tests.jl`, `test/http_server_http1_tests.jl`, `test/http_parity_tests.jl`
- Implementation notes:
  - Introduce explicit HTTP header field-name validation for token syntax before serialization.
  - Introduce explicit header field-value validation or sanitization that strips or rejects embedded CR/LF and leading/trailing invalid whitespace.
  - Decide whether to drop invalid outgoing headers or raise an exception; use one behavior consistently and document it.
  - Validate trailer names before emitting the `Trailer` header and before serializing trailer fields.
  - Re-check all places that synthesize outbound headers: normal HTTP/1 requests, proxy CONNECT, server responses, websocket handshakes, and SSE responses.
- Verification:
  - `julia --project=. test/runtests.jl`
  - Add a regression test that attempts to serialize a header value containing `\r\nInjected: yes` and verifies that a second header line is not emitted.
  - Add regression tests for invalid trailer keys and invalid header field names.
- Assumptions:
  - Failing closed is acceptable for malformed user-supplied headers in this hardening pass.
  - Existing public APIs do not need to preserve the ability to write raw invalid headers.
  - Execution assumption for implementation: normalize embedded CR/LF to spaces and trim outer OWS in outgoing field values like Go, but reject invalid field names, invalid remaining control bytes, and forbidden trailer names before any HTTP/1 bytes are written.
- Risks:
  - Some callers may currently rely on permissive serialization for non-standard headers.
  - Tests that assert exact wire output will need careful updates.
- Completion criteria:
  - Header injection via CRLF in names/values is impossible through HTTP/1 request/response writers.
  - Invalid trailer keys are rejected or dropped intentionally.
  - Regression tests cover both request and response serialization paths.
- Verification evidence:
  - `julia --project=. test/http1_wire_tests.jl`
  - `julia --project=. test/http_server_http1_tests.jl`
  - `julia --project=. test/runtests.jl`

### [x] ITEM-003 (P0) Bring HTTP/1 framing and transfer-coding hardening to Go parity
- Description: HTTP/1 parsing and writing currently take unsafe shortcuts around `Transfer-Encoding`, `Content-Length`, header syntax, `Host`, and request-target validation. Unsupported transfer codings can be treated as empty bodies, chunked messages keep stale `Content-Length`, forwarded chunked requests can emit both headers, whitespace-before-colon header lines are accepted, and HTTP/1.1 requests can slip through without a valid `Host`.
- Desired outcome: HTTP/1 request/response framing decisions match Go's strict transfer rules closely enough to remove smuggling-class ambiguities and malformed-wire acceptance.
- Affected files: `src/http1.jl`, `src/http_transport.jl`, `src/http_server.jl`, `src/http_client.jl`, `test/http1_wire_tests.jl`, `test/http_client_transport_tests.jl`, `test/http_server_http1_tests.jl`, `test/http_parity_tests.jl`
- Implementation notes:
  - Implement strict transfer-coding parsing: reject unsupported codings, reject multiple transfer-coding lines where appropriate, and ignore `Transfer-Encoding` on HTTP/1.0 only where Go does.
  - When chunked framing is accepted, strip any `Content-Length` from parsed headers before the request/response object is exposed or reserialized.
  - Normalize duplicate `Content-Length` values by deduplicating equal values and rejecting mismatched values.
  - Reject whitespace between field name and colon instead of accepting lines like `Host : example.com`.
  - Enforce HTTP/1.1 `Host` requirements on the server side: reject missing, duplicated, or invalid `Host` values instead of passing them through to handlers.
  - Revisit request-target validation so clearly invalid targets that Go rejects do not silently pass through.
  - Validate trailer handling in chunked bodies and make sure malformed chunk extensions/footers remain fatal.
  - Re-audit proxy forwarding and websocket upgrade paths after transfer-coding changes.
- Verification:
  - `julia --project=. test/runtests.jl`
  - Add targeted regression tests for:
    - unsupported `Transfer-Encoding: gzip`
    - duplicate `Transfer-Encoding` lines
    - chunked + stale `Content-Length` parsing and forwarding
    - HTTP/1.1 request without `Host`
    - `Host : example.com` and other whitespace-before-colon header lines
    - invalid/malformed request-targets that Go rejects
  - Add a reproducer showing that a parsed chunked request cannot later be re-emitted with both `Transfer-Encoding` and `Content-Length`.
- Assumptions:
  - Matching Go's strictness is more important than preserving permissive handling of oddball peers.
  - Some malformed inputs that currently "work" should become hard failures.
  - Execution assumption for implementation: preserve the existing parsed-request shape by keeping `Host` inside `request.headers`, but harden validation/count semantics and framing normalization around `Host`, `Content-Length`, and `Transfer-Encoding`.
- Risks:
  - Tightening parsing may break existing users that depend on permissive behavior.
  - Header representation changes from ITEM-001 will interact with this work.
- Completion criteria:
  - Unsupported or ambiguous transfer-coding inputs are rejected.
  - Chunked messages never retain or re-emit a stale `Content-Length`.
  - New framing tests explicitly cover the reviewed smuggling vectors.
- Verification evidence:
  - `julia --project=. test/http1_wire_tests.jl`
  - `julia --project=. test/http_server_http1_tests.jl`
  - `julia --project=. test/http_parity_tests.jl`
  - `julia --project=. test/trim_compile_tests.jl`
  - `julia --project=. test/runtests.jl`

### [x] ITEM-004 (P0) Validate HTTP/2 client response headers and build correct outbound pseudo-headers
- Description: The HTTP/2 client currently accepts malformed response header sets and constructs invalid request headers. Missing `:status` silently defaults to `200`, response pseudo-header ordering/content is not validated, `:authority` ignores `request.host` and strips non-default ports, and forbidden connection-specific headers can be forwarded over HTTP/2.
- Desired outcome: Client-side HTTP/2 request/response header handling is protocol-correct and matches Go's expectations for pseudo-header validation, authority selection, and forbidden header filtering.
- Affected files: `src/http2_client.jl`, `src/http_client.jl`, `src/http_core.jl`, `test/http2_client_tests.jl`, `test/http_integration_tests.jl`, `test/http_parity_tests.jl`
- Implementation notes:
  - Replace `_decode_response_headers` with a validation path that requires `:status`, rejects duplicate/invalid pseudo-headers, rejects connection-specific headers, and preserves legal regular headers/trailers correctly.
  - Build `:authority` from `request.host` when explicitly set; otherwise use the request authority including non-default ports, not only the bare host.
  - Filter forbidden headers from outgoing HTTP/2 requests: `connection`, `proxy-connection`, `keep-alive`, `upgrade`, `transfer-encoding`, and invalid `te` values.
  - Decide how to surface malformed response headers: connection error, stream error, or protocol exception; align with existing client error taxonomy.
  - Re-audit CONNECT and proxy-tunneled H2 paths so authority handling remains correct there too.
- Verification:
  - `julia --project=. test/runtests.jl`
  - Add regression tests for:
    - response without `:status`
    - duplicate `:status`
    - forbidden response headers
    - explicit `request.host` override
    - non-default port in `:authority`
    - outgoing `Connection` / `Transfer-Encoding` stripping
- Assumptions:
  - Rejecting malformed H2 responses is acceptable even if some permissive peers currently pass.
  - The current public request API should continue to allow `request.host` overrides.
  - Execution assumption for implementation: this item validates the initial response header block and outbound request pseudo-header construction only; distinct trailing-header lifecycle work remains in ITEM-008.
- Risks:
  - This item touches both wire correctness and public-facing request behavior.
  - Existing H2 tests are happy-path oriented and will need significant extension.
- Completion criteria:
  - Malformed HTTP/2 response headers no longer decode as `200`.
  - Outgoing H2 requests send correct `:authority` values and never send forbidden connection-specific headers.
  - New client tests cover each reviewed malformed-header case.
- Verification evidence:
  - `julia --project=. test/http2_client_tests.jl`
  - `julia --project=. test/runtests.jl`

### [x] ITEM-005 (P0) Implement HTTP/2 header-block fragmentation and persistent server-side HPACK encoder state
- Description: Outgoing HTTP/2 request and response header blocks are emitted as a single `HEADERS` frame and fail once the HPACK block exceeds 16 KB or the peer advertises a smaller max frame size. On the server side, a new HPACK encoder is constructed per response/trailer, which throws away dynamic-table reuse and ignores per-connection peer constraints.
- Desired outcome: HTTP/2 header blocks are automatically split into `HEADERS` + `CONTINUATION` sequences as needed, and server-side HPACK encoding is connection-scoped like Go's implementation.
- Affected files: `src/http2.jl`, `src/http2_client.jl`, `src/http_server.jl`, `test/http2_frame_tests.jl`, `test/http2_client_tests.jl`, `test/http2_server_tests.jl`
- Implementation notes:
  - Introduce a shared helper for splitting header blocks into one initial `HEADERS` frame plus zero or more `CONTINUATION` frames based on the active max send frame size.
  - Update client request writes to use the helper instead of assuming one frame.
  - Update server response/trailer writes to use the helper and keep an HPACK encoder per connection, not per response.
  - Ensure CONTINUATION sequencing remains valid and END_HEADERS is set only on the final fragment.
  - Revisit trailer header emission once fragmentation is implemented so large trailers work too.
- Verification:
  - `julia --project=. test/runtests.jl`
  - Add client and server tests with request/response headers large enough to exceed 16 KB and verify successful fragmentation.
  - Add a framer-level test asserting the exact sequence of `HEADERS` then `CONTINUATION` frames and the placement of END_HEADERS.
- Assumptions:
  - Introducing a shared helper for header-block splitting is acceptable if it stays narrow and wire-focused.
  - Persisting server-side encoder state per connection is desirable even if it changes compression behavior.
  - Execution assumption for implementation: store the server HPACK encoder on the per-connection send state and guard encode/write as one critical section under the existing HTTP/2 write lock.
- Risks:
  - HPACK dynamic-table state must remain synchronized with the peer after fragmentation changes.
  - Server-side refactoring here intersects with later settings/limits work.
- Completion criteria:
  - Large HTTP/2 headers no longer fail solely because they exceed one frame.
  - Server-side header compression state persists across responses on the same connection.
  - New tests explicitly cover fragmented request headers, response headers, and trailer headers.
- Verification evidence:
  - `julia --project=. test/http2_frame_tests.jl`
  - `julia --project=. test/http2_client_tests.jl`
  - `julia --project=. test/http2_server_tests.jl`
  - `julia --project=. test/runtests.jl`

### [x] ITEM-006 (P0) Add HTTP/2 and HPACK size limits, allowed-table-size bounds, and header bomb defenses
- Description: The current HTTP/2 and HPACK code paths have no total header-list limit, no max decoded string length, no cap on accumulated CONTINUATION/header-block bytes, and no enforcement of allowed dynamic table size updates. A peer can force large allocations or grow decoder state far beyond the intended Go limits.
- Desired outcome: Both client and server bound header memory growth and reject peers that exceed configured or spec-derived limits, with behavior that tracks Go's framer/decoder defenses closely.
- Affected files: `src/hpack.jl`, `src/http2_client.jl`, `src/http_server.jl`, `src/http2.jl`, `test/hpack_tests.jl`, `test/http2_client_tests.jl`, `test/http2_server_tests.jl`
- Implementation notes:
  - Extend `Decoder` with an allowed max dynamic table size and reject table-size updates above it.
  - Add configurable max decoded string length and max total header-list size limits to HPACK decoding.
  - Add per-stream accumulated header-block size limits for both client and server while appending CONTINUATION fragments.
  - Decide where the limits should live: connection state, framer config, server config, and/or client config, and keep the public surface minimal.
  - Make failure modes explicit and protocol-correct: distinguish stream-local bad headers from connection-level framing violations where possible.
- Verification:
  - `julia --project=. test/runtests.jl`
  - Add regression tests for:
    - oversized HPACK string literal
    - oversized accumulated header block across CONTINUATION frames
    - dynamic table size update above the allowed limit
    - oversized header list on both client and server
- Assumptions:
  - New limit knobs are acceptable if kept narrowly scoped and documented.
  - It is acceptable to add internal defaults first and consider public configurability later if needed.
  - Execution assumption for implementation: use internal per-connection defaults on the client, derive server-side decode limits from `Server.max_header_bytes`, and expose only the existing mutable internal state needed by targeted tests.
- Risks:
  - Too-small defaults could reject legitimate traffic; too-large defaults reduce the value of the hardening.
  - The client and server should use compatible defaults to avoid surprising asymmetry.
- Completion criteria:
  - Header bombs and oversized HPACK table updates are rejected deterministically.
  - Client/server tests cover both per-header and accumulated-size violations.
  - Decoder state cannot grow without bound from peer-controlled input.
- Verification evidence:
  - `julia --project=. test/hpack_tests.jl`
  - `julia --project=. test/http2_client_tests.jl`
  - `julia --project=. test/http2_server_tests.jl`
  - `julia --project=. test/runtests.jl`

### [x] ITEM-007 (P0) Respect peer HTTP/2 settings and real connection concurrency semantics
- Description: The client currently ignores several important peer settings and behaves as if one cached HTTP/2 connection can accept unlimited new streams forever. That diverges materially from Go's `http2Transport`, which tracks `MAX_CONCURRENT_STREAMS`, peer header-table size, peer max header list size, and connection usability/GOAWAY state.
- Desired outcome: HTTP/2 connection reuse, new-stream admission, and HPACK encoder constraints honor peer settings and Go-like connection lifecycle rules.
- Affected files: `src/http2_client.jl`, `src/http_client.jl`, `src/http_server.jl`, `test/http2_client_tests.jl`, `test/http_integration_tests.jl`
- Implementation notes:
  - During client connection preface/setup, require the first server frame to be a non-ACK `SETTINGS` frame instead of tolerating arbitrary pre-SETTINGS frames like `PING`.
  - Reject explicitly illegal server settings such as `SETTINGS_ENABLE_PUSH = 1` instead of silently accepting them.
  - Track peer `SETTINGS_MAX_CONCURRENT_STREAMS` and block or open a new H2 connection when the existing one is at capacity.
  - Track peer `SETTINGS_HEADER_TABLE_SIZE` and propagate that to the client encoder and any server-side per-connection encoder.
  - Track peer `SETTINGS_MAX_HEADER_LIST_SIZE` once ITEM-006 introduces header-list limits.
  - On the server side, process duplicate settings parameters in-order instead of treating duplicate IDs in one `SETTINGS` frame as a protocol error.
  - Decide how `Client` should cache multiple H2 connections per origin when concurrency caps or GOAWAY make a single session insufficient.
  - Tighten GOAWAY handling so streams above `last_stream_id` are retried or failed intentionally instead of being treated generically.
  - Disable or explicitly reject server push on the client side instead of silently ignoring `PUSH_PROMISE`.
- Verification:
  - `julia --project=. test/runtests.jl`
  - Add tests for:
    - server `PING` before initial `SETTINGS` being rejected
    - server `SETTINGS_ENABLE_PUSH = 1` being rejected
    - peer advertising `MAX_CONCURRENT_STREAMS = 1` while two concurrent client requests are issued
    - peer reducing header-table size and client encoder complying
    - duplicate settings parameters being accepted in-order on the server side
    - GOAWAY with low `last_stream_id`
    - incoming `PUSH_PROMISE` rejection/disable-push behavior
- Assumptions:
  - Supporting more than one H2 connection per origin is acceptable and preferable to violating peer concurrency limits.
  - Client-side server push is still intentionally unsupported and should be explicitly disabled/rejected.
  - Execution assumption for implementation: keep the public API unchanged, teach `Client` to manage a small pool of reusable H2 connections per origin internally, and treat graceful GOAWAY as "no new streams" plus targeted stream failures instead of an unconditional connection-wide abort.
- Risks:
  - This is the biggest behavior change in the current H2 pooling design.
  - Correct retry semantics after GOAWAY or refused streams will need careful coordination with higher-level request retry code.
- Completion criteria:
  - The client no longer opens streams beyond peer-advertised concurrency.
  - Encoder state honors peer-advertised header-table constraints.
  - GOAWAY and push-related behaviors are covered by dedicated tests.
- Verification evidence:
  - `julia --project=. test/http2_client_tests.jl`
  - `julia --project=. test/http2_server_tests.jl`
  - `julia --project=. test/http_integration_tests.jl`
  - `julia --project=. test/runtests.jl`

### [x] ITEM-008 (P1) Complete HTTP/2 trailer handling and remaining request/response header lifecycle gaps
- Description: HTTP/2 request trailers are currently rejected on the server, and client-side response trailer handling is effectively missing. Additional HEADERS on a request stream are treated as protocol errors even when they are legal trailers, and the client does not expose or preserve response trailers in a useful way.
- Desired outcome: Legal HTTP/2 trailers are supported end-to-end, and stream/header lifecycle rules distinguish initial headers from trailers correctly.
- Affected files: `src/http2_client.jl`, `src/http_server.jl`, `src/http_core.jl`, `test/http2_client_tests.jl`, `test/http2_server_tests.jl`
- Implementation notes:
  - On the server side, allow post-body HEADERS as trailers when the stream is already in header-complete state and trailer semantics are valid.
  - On the client side, differentiate first response headers from trailing headers and surface trailers on the `Response` object after body EOF.
  - Validate that trailer blocks contain no pseudo-headers and respect END_STREAM rules.
  - Revisit body close and stream cleanup paths so trailers are not lost due to eager unregistration.
- Verification:
  - `julia --project=. test/runtests.jl`
  - Add tests for:
    - client receiving legal response trailers
    - server receiving legal request trailers
    - invalid trailer pseudo-headers being rejected
    - trailers arriving only after the body is fully consumed
- Assumptions:
  - Exposing HTTP/2 trailers through the existing `Response.trailers` model is acceptable.
  - Execution assumption for implementation: keep trailer state on each H2 stream, publish response trailers only after body EOF, and reuse the same trailer validation rules on both client and server so pseudo-headers remain forbidden everywhere.
- Risks:
  - Trailer handling interacts with body-close, flow-control, and stream cleanup logic.
  - Existing tests may assume HEADERS-after-HEADERS is always invalid.
- Completion criteria:
  - Legal HTTP/2 trailers work on both client and server sides.
  - Invalid trailer header blocks are still rejected.
  - Tests prove trailers are visible only after EOF, matching HTTP semantics.
- Verification evidence:
  - `julia --project=. test/http2_client_tests.jl`
  - `julia --project=. test/http2_server_tests.jl`
  - `julia --project=. test/runtests.jl`

### [x] ITEM-009 (P1) Tighten HTTP/2 framer validation and malformed-frame handling to Go parity
- Description: The framer currently accepts illegal stream IDs and some connection-only frame placements that Go's framer rejects immediately. That leaves too much malformed-input handling to higher layers and makes client/server behavior less predictable when peers are buggy or hostile.
- Desired outcome: The framer enforces the core stream-ID and frame-class invariants that Go enforces at the frame layer, while leaving true stream-state sequencing to the caller.
- Affected files: `src/http2.jl`, `test/http2_frame_tests.jl`, `test/http_parity_tests.jl`
- Implementation notes:
  - Reject stream-id-zero `DATA`, `HEADERS`, `PRIORITY`, `RST_STREAM`, `PUSH_PROMISE`, and `CONTINUATION` frames on read and write.
  - Reject non-zero stream IDs for `SETTINGS`, `PING`, and `GOAWAY`.
  - Consider whether `WINDOW_UPDATE` on stream 0 remains valid while other stream-specific placements are tightened.
  - Keep frame-layer and stream-state-layer responsibilities clearly separated in code and tests.
- Verification:
  - `julia --project=. test/runtests.jl`
  - Add explicit framer tests for illegal stream-ID combinations on both read and write paths.
- Assumptions:
  - Adding frame-layer validation will not conflict with legitimate higher-level tests that intentionally inject malformed frames.
  - Execution assumption for implementation: keep stream-state sequencing in the higher layers, but fail obviously illegal stream-id/frame-class combinations directly in the framer on both read and write paths.
- Risks:
  - Some existing ad hoc tests may rely on permissive framer behavior for setup convenience.
- Completion criteria:
  - Illegal stream-ID/frame-class combinations fail at the framer layer.
  - New tests cover both inbound and outbound validation.
- Verification evidence:
  - `julia --project=. test/http2_frame_tests.jl`
  - `julia --project=. test/http_parity_tests.jl`
  - `julia --project=. test/runtests.jl`

### [x] ITEM-010 (P1) Close remaining HTTP/1 transport parity gaps with Go's mature client transport
- Description: The HTTP/1 transport currently takes several deliberate shortcuts versus Go: it writes the full request before reading any response, has no client-side `Expect: 100-continue` path, and always destroys keep-alive reuse on early body close instead of attempting a bounded drain. It also does not treat a caller-supplied `Connection: close` header on the request as strongly as Go's request-close semantics.
- Desired outcome: HTTP/1 client transport behavior is closer to Go in the cases that matter for production performance and correctness under large uploads, early server responses, and connection reuse.
- Affected files: `src/http_transport.jl`, `test/http_client_transport_tests.jl`
- Implementation notes:
  - Add an `Expect: 100-continue` path that can defer body upload until the interim response or timeout.
  - Revisit request write/read concurrency so servers that answer before full body upload do not force unnecessary upload latency.
  - Consider a bounded drain-on-close strategy for managed response bodies so some early closes can still preserve the connection.
  - Treat an explicit request `Connection: close` header as non-reusable even if `request.close` was not set directly.
- Verification:
  - `julia --project=. test/runtests.jl`
  - Add targeted transport tests for:
    - `Expect: 100-continue`
    - early final response before request body completes
    - bounded drain preserving reuse when safe
    - request header `Connection: close` preventing reuse
- Assumptions:
  - Matching Go's mature behavior here is worth the added complexity because this package is preparing for production release.
- Risks:
  - This item can introduce subtle races or deadlocks if write/read coordination is implemented carelessly.
  - Drain-on-close must be bounded tightly to avoid hangs.
- Completion criteria:
  - The transport handles `Expect: 100-continue` and early-response cases intentionally.
  - Reuse decisions match explicit caller and peer close signals more closely.
  - New transport tests cover all added behavior.
- Verification evidence:
  - `julia --project=. test/http_client_transport_tests.jl`
  - `julia --project=. test/runtests.jl`

### [x] ITEM-011 (P1) Add CGI-safe proxy environment handling and finish proxy semantics parity review
- Description: Environment proxy handling currently trusts `HTTP_PROXY` unconditionally, unlike Go's well-known CGI safeguard. Given the hardening scope, proxy env behavior should align with Go's security posture before release.
- Desired outcome: `ProxyFromEnvironment` is safe in CGI-style environments and matches the expected precedence/error behavior of Go closely enough for production use.
- Affected files: `src/http_proxy.jl`, `test/http_client_proxy_tests.jl`
- Implementation notes:
  - Detect CGI-style environments via `REQUEST_METHOD` and refuse `HTTP_PROXY` in that case.
  - Decide whether the refusal should surface as an error, `nothing`, or a logged warning in this API shape, and make it consistent.
  - Re-audit env precedence (`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`) after the CGI behavior is introduced.
- Verification:
  - `julia --project=. test/runtests.jl`
  - Add proxy tests for CGI environments with `REQUEST_METHOD` set and `HTTP_PROXY` populated.
  - Add explicit assertions for unaffected `HTTPS_PROXY` / `ALL_PROXY` behavior.
- Assumptions:
  - Matching Go's CGI hardening is desired even if it changes behavior for a small number of environments.
- Risks:
  - The current API returns `ProxyConfig` directly, so representing refusal/error semantics may require careful API design.
- Completion criteria:
  - CGI environments no longer honor `HTTP_PROXY`.
  - Proxy env tests cover the hardened behavior explicitly.
- Verification evidence:
  - `julia --project=. test/http_client_proxy_tests.jl`
  - `julia --project=. test/runtests.jl`

### [x] ITEM-012 (P1) Expand regression coverage so the hardening findings are permanently locked in
- Description: The current suite passes while still missing several of the highest-risk review findings. Even after the fixes above, the package should not rely on broad happy-path coverage alone.
- Desired outcome: Every review finding that motivated this hardening pass has a focused regression test or explicit negative test case.
- Affected files: `test/http_core_tests.jl`, `test/http1_wire_tests.jl`, `test/http_client_transport_tests.jl`, `test/http_client_proxy_tests.jl`, `test/http2_frame_tests.jl`, `test/http2_client_tests.jl`, `test/http2_server_tests.jl`, `test/http_parity_tests.jl`
- Implementation notes:
  - Add a coverage matrix section to this file as items land, mapping each review finding to at least one regression test.
  - Keep targeted tests close to the subsystem they protect instead of creating a giant catch-all file.
  - Include exact repros for the manually confirmed bugs found during review:
    - CRLF header injection
    - unsupported/ambiguous transfer encoding
    - missing HTTP/1.1 `Host`
    - whitespace before the header colon
    - stale `Content-Length` on chunked forwarding
    - non-stream HTTP/1 `HEAD` responses incorrectly sending bodies
    - missing H2 `:status`
    - incorrect H2 `:authority`
    - server `PING` before initial H2 `SETTINGS`
    - server `SETTINGS_ENABLE_PUSH = 1`
    - duplicate H2 `SETTINGS` parameters being rejected by the server
    - oversized H2/HPACK header blocks
    - CGI `HTTP_PROXY`
    - invalid `Sec-WebSocket-Key`
    - non-zero WebSocket RSV bits without extensions
- Verification:
  - `julia --project=. test/runtests.jl`
  - Review the item-to-test mapping in this document and confirm every completed item has durable regression coverage.
- Assumptions:
  - Some tests will necessarily be fairly low-level because the bugs are wire-level and security-sensitive.
- Risks:
  - Test setup complexity may tempt future shortcuts; keep helpers small and local.
- Completion criteria:
  - Every completed hardening item has at least one focused regression test.
  - The action-item document includes a clear mapping from findings to tests.
- Verification evidence:
  - Coverage matrix added below and reviewed against completed items.
  - `julia --project=. test/runtests.jl`

### [x] ITEM-013 (P2) Decide how to handle intentionally missing Go features before release documentation is finalized
- Description: Some gaps versus Go are larger feature omissions rather than bugs: no HTTP/2 server push / `Pusher`, no `ResponseController` / hijack-style surface, no full Go-style `httptrace` breadth, and no Go-equivalent `net/url` / `ServeMux` feature parity. These may be acceptable, but they should be made explicit before release rather than discovered ad hoc.
- Desired outcome: The package has a clear, intentional list of unsupported or deferred Go features, with documentation and release messaging that distinguish them from bugs.
- Affected files: `README.md`, `CHANGELOG.md`, `docs/`, potentially `src/http_server.jl`, `src/http_client.jl`, `src/http_handlers.jl`
- Implementation notes:
  - Decide which missing Go features are in scope for this release and which are explicitly deferred.
  - Document deferred items clearly so future work can prioritize them without confusing them with regressions.
  - Do not add compatibility shims or partial placeholder APIs unless explicitly requested.
- Verification:
  - Review the release notes / docs diff manually.
  - `julia --project=. test/runtests.jl`
- Assumptions:
  - Not every Go `net/http` feature needs to exist before a production release, but the omissions must be explicit.
- Risks:
  - This item should not dilute focus from the P0/P1 hardening work.
- Completion criteria:
  - There is a documented, explicit list of intentionally deferred Go features.
  - Release messaging distinguishes deferred features from resolved hardening issues.
- Verification evidence:
  - Reviewed the README, docs, and changelog diffs for explicit deferred-feature messaging.
  - `julia --project=. test/runtests.jl`

## Coverage Matrix

| Item | Findings Covered | Regression Coverage |
| --- | --- | --- |
| `ITEM-001` | Repeated-header semantics, duplicate-sensitive-header stripping | `test/http_core_tests.jl`: `HTTP core headers`; `test/http_client_tests.jl`: `HTTP client redirect helper strips all duplicate sensitive headers` |
| `ITEM-002` | CRLF/header serialization hardening | `test/http1_wire_tests.jl`: `HTTP/1 header serialization hardening`; `HTTP/1 header serialization preserves stored entries` |
| `ITEM-003` | HTTP/1 framing, TE/CL ambiguity, invalid header syntax, missing host | `test/http1_wire_tests.jl`: `HTTP/1 parse and framing errors`; `test/http_parity_tests.jl`: `HTTP parity framing guards` |
| `ITEM-004` | H2 response pseudo-header validation and correct request pseudo-headers | `test/http2_client_tests.jl`: `HTTP/2 client request header filtering and authority selection`; `HTTP/2 client validates response pseudo-headers`; `HTTP/2 client rejects response without status pseudo-header` |
| `ITEM-005` | H2 header-block fragmentation and persistent HPACK encoder state | `test/http2_client_tests.jl`: `HTTP/2 client fragments large request headers`; `test/http2_server_tests.jl`: `HTTP/2 server fragments large response headers`; `HTTP/2 server fragments large response trailers`; `HTTP/2 server reuses HPACK encoder state across responses` |
| `ITEM-006` | HPACK string/header-list limits and accumulated H2 header-block caps | `test/hpack_tests.jl`: `HPACK decoder enforces max decoded string length`; `HPACK decoder enforces max header list size`; `test/http2_client_tests.jl`: `HTTP/2 client rejects oversized accumulated response header blocks`; `HTTP/2 client rejects oversized decoded response header lists`; `test/http2_server_tests.jl`: `HTTP/2 server rejects oversized request header blocks`; `HTTP/2 server rejects oversized decoded request header lists` |
| `ITEM-007` | Initial SETTINGS requirements, peer settings, push rejection, concurrency caps | `test/http2_client_tests.jl`: `HTTP/2 client requires initial SETTINGS before other frames`; `HTTP/2 client rejects server ENABLE_PUSH settings`; `HTTP/2 client honors peer header table size settings`; `test/http2_server_tests.jl`: `HTTP/2 server honors peer header table size settings`; `HTTP/2 server accepts duplicate peer settings in order`; `test/http_integration_tests.jl`: `HTTP integration opens additional h2 connections under peer concurrency caps` |
| `ITEM-008` | HTTP/2 request/response trailer lifecycle | `test/http2_client_tests.jl`: `HTTP/2 client exposes response trailers after body EOF`; `HTTP/2 client rejects invalid response trailer pseudo-headers`; `test/http2_server_tests.jl`: `HTTP/2 server accepts legal request trailers`; `HTTP/2 server rejects invalid request trailer pseudo-headers` |
| `ITEM-009` | Framer-level invalid stream-id and frame-class validation | `test/http2_frame_tests.jl`: `HTTP/2 frame stream-id validation on read`; `HTTP/2 frame stream-id validation on write`; `test/http_parity_tests.jl`: `HTTP parity h2 frame validation` |
| `ITEM-010` | `Expect: 100-continue`, early final responses, bounded drain reuse, request `Connection: close` | `test/http_client_transport_tests.jl`: `HTTP client transport waits for 100-continue before sending body`; `HTTP client transport returns early final responses before upload completes`; `HTTP client transport bounded drain preserves reuse on early close`; `HTTP client transport respects request Connection close` |
| `ITEM-011` | CGI `HTTP_PROXY` safeguard and unaffected env proxy behavior | `test/http_client_proxy_tests.jl`: `HTTP proxy CGI safeguard matches Go semantics`; `HTTP default client surfaces CGI HTTP_PROXY refusal`; `HTTP proxy env selection and all_proxy fallback` |
| `ITEM-014` | HTTP/1 `HEAD` body suppression on non-stream handlers | `test/http_server_http1_tests.jl`: `HTTP server ordinary handlers suppress bodies for HEAD`; `HTTP server stream handlers suppress bodies for HEAD, 204, and 304`; `test/http_parity_tests.jl`: `HTTP parity framing guards` |
| `ITEM-015` | Invalid websocket keys and RSV-bit validation | `test/http_websocket_codec_tests.jl`: `HTTP websocket handshake helpers`; `HTTP websocket decoder`; `test/http_websocket_server_tests.jl`: `HTTP.WebSockets server rejects invalid websocket keys` |

### [x] ITEM-014 (P0) Fix HTTP/1 response semantics for `HEAD` on non-stream server handlers
- Description: The HTTP/1 server currently suppresses bodies for `HEAD` only on the stream-handler path. Ordinary request-handler responses can still serialize body bytes on `HEAD`, which is a wire-visible standards violation and was directly reproduced during review.
- Desired outcome: HTTP/1 `HEAD` responses never send body bytes regardless of whether the server is using stream handlers or ordinary request handlers.
- Affected files: `src/http1.jl`, `test/http_server_http1_tests.jl`, `test/http_parity_tests.jl`
- Implementation notes:
  - Decide whether `write_response!` should become request-aware for `HEAD`, or whether the server should normalize/suppress the body before calling it on ordinary handler paths.
  - Keep `Content-Length` semantics correct for `HEAD`: metadata should still reflect the GET-equivalent response where appropriate even though no body bytes are sent.
  - Re-audit `204`, `304`, and CONNECT tunnel responses after the change so the suppression rules stay internally consistent.
- Verification:
  - `julia --project=. test/runtests.jl`
  - Add a regression test covering a non-stream HTTP/1 server handler returning `BytesBody("oops")` to a `HEAD` request and assert that no body bytes reach the wire.
- Assumptions:
  - Fixing `HEAD` semantics centrally is preferable to relying on every handler to special-case it manually.
- Risks:
  - If the fix lands in generic response serialization, it could affect call sites outside the server.
- Completion criteria:
  - Non-stream HTTP/1 handlers no longer emit body bytes on `HEAD`.
  - New tests cover both stream-handler and ordinary-handler `HEAD` behavior.
- Verification evidence:
  - `julia --project=. test/http_parity_tests.jl`
  - `julia --project=. test/http_server_http1_tests.jl`
  - `julia --project=. test/runtests.jl`

### [x] ITEM-015 (P1) Tighten WebSocket handshake and frame validation to RFC 6455 parity
- Description: WebSocket validation currently accepts handshakes with invalid `Sec-WebSocket-Key` values and accepts frames with non-zero RSV bits even though no extensions are negotiated. Those are concrete protocol-validation gaps that were manually confirmed during review.
- Desired outcome: WebSocket handshakes and frame parsing reject invalid nonce/key material and reject RSV usage unless an extension explicitly permits it, matching RFC 6455 much more closely.
- Affected files: `src/http_websocket_codec.jl`, `src/http_websockets.jl`, `test/http_websocket_codec_tests.jl`, `test/http_websocket_server_tests.jl`
- Implementation notes:
  - Validate `Sec-WebSocket-Key` as base64 that decodes to exactly 16 bytes before treating a request as a valid upgrade candidate.
  - Ensure the server returns a normal handshake failure for invalid websocket keys instead of generating `Sec-WebSocket-Accept` from arbitrary strings.
  - Reject non-zero RSV bits on incoming frames unless/until extension negotiation support exists.
  - Re-audit close/error mapping so invalid RSV and invalid key failures surface as the correct protocol-close or handshake-failure behavior.
- Verification:
  - `julia --project=. test/runtests.jl`
  - Add regression tests for:
    - `Sec-WebSocket-Key: x`
    - malformed base64 websocket keys
    - valid base64 that does not decode to 16 bytes
    - incoming text/binary/control frames with `RSV1`, `RSV2`, or `RSV3` set
- Assumptions:
  - Extension negotiation remains out of scope for this hardening pass, so RSV bits should be treated as invalid by default.
- Risks:
  - Some existing ad hoc websocket peers may currently rely on permissive key handling and will start failing.
- Completion criteria:
  - Invalid websocket keys no longer pass `ws_is_websocket_request` or server upgrade validation.
  - Frames with non-zero RSV bits are rejected when no extension is active.
  - Dedicated websocket regression tests cover both handshake and framing failures.
- Verification evidence:
  - `julia --project=. test/http_websocket_codec_tests.jl`
  - `julia --project=. test/http_websocket_client_tests.jl`
  - `julia --project=. test/http_websocket_server_tests.jl`
  - `julia --project=. test/http_client_transport_tests.jl`
  - `julia --project=. test/runtests.jl`

## Compaction Continuity Block

```text
* Take investigation/review findings and make a detailed, prioritized action item .md file; ensure each action item has enough detail (description, affected files, etc.) that a fresh context/engineer "taking on" the item would understand what needs to be done and where to go to get started and ideally how to verify that it's done
* Start working on the action-item list, for each item:
  * Thoroughly investigate the action item and work involved, state assumptions, do the work, including verification step
  * Work until verification succeeds (i.e. tests pass)
  * Mark the item done in the action item list
  * Commit the work involved for this action item
  * Continue with the same steps on the next action item
* When compacting, the itemizer instructions should be preserved *exactly* to ensure continuity
* The action-item document should very clearly state the repo/worktree where the work should be done
* Post-compaction, if there are unstaged edits in files relating to the current action item, you should assume they were your own edits and should continue directly w/ work without pausing to confirm
* No shortcuts or cutting corners while doing the action item work; each item should be done thoughtfully, carefully, with production-quality effort/work put into it; we're not trying to rush the work here at all and prefer quality, robustness, and thoroughness over "quick wins".
* No backwards compat or unnecessary shims should be included unless specifically requested
```
