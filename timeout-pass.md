# Action Items: Client Timeout Overhaul

## Context
- Repo: HTTP.jl
- Worktree: /Users/jacob.quinn/.julia/dev/HTTP
- Branch: codex/http-2.0-extraction

## Items

### [x] ITEM-001 (P0) Introduce request-scoped timeout configuration and public API plumbing
- Description: The current client surface only exposes `connect_timeout` and `readtimeout`, and those keywords do not represent a complete or transport-agnostic timeout model. `connect_timeout` is currently limited to implicit clients, while `readtimeout` is implemented as an overall deadline even though users expect the HTTP.jl `master` inactivity-style behavior. Add a first-class request-scoped timeout configuration model, thread it through the high-level request/open/websocket entry points, and deprecate `readtimeout` with a once-only warning while mapping it to the closest new timeout behavior.
- Desired outcome: Public client APIs accept explicit timeout knobs for the major phases of an outbound request, `readtimeout` remains supported but deprecated, and timeout state is carried per request instead of being implicit in only one transport path. Until the deeper transport timeout items land, `readtimeout` should also preserve the existing overall/header timeout behavior so current callers do not silently lose protection.
- Affected files: `src/http_client.jl`, `src/http_stream.jl`, `src/http_websockets.jl`, `src/http_core.jl`, `src/HTTP.jl`, `test/http_client_tests.jl`, `test/http_stream_tests.jl`, `test/http_websocket_client_tests.jl`
- Implementation notes:
  - Add a typed timeout/state container that can live on `RequestContext` or in request metadata without relying on loose dictionaries for every lookup.
  - Define new per-request keywords for at least: overall request deadline, connect timeout, response-header timeout, read idle timeout, write idle timeout, and expect-continue timeout.
  - Preserve `readtimeout` as a deprecated alias for the closest `master` behavior, using a once-only warning via Julia logging metadata rather than a custom spammy warning path.
  - Make the parsing/validation behavior identical across `request`, `HTTP.open`, and websocket client entry points where the semantics apply.
- Verification:
  - `julia --project=. -e 'using Test; using HTTP; using Reseau; _http_windows_ci() = false; include("test/http_client_tests.jl")'`
  - `julia --project=. test/http_websocket_client_tests.jl`
- Assumptions:
  - This pass is client-focused; existing server timeout knobs are out of scope unless a refactor necessarily touches shared helpers.
  - Default values should remain effectively disabled/off unless there is already an established transport default in the rewrite.
- Risks:
  - The request/open/websocket surfaces currently share timeout names only loosely; centralizing them without careful validation could create silent behavior differences.
- Completion criteria:
  - The public client APIs accept the new timeout keywords with consistent validation.
  - `readtimeout` emits a once-only deprecation warning, seeds the new inactivity-style timeout settings, and preserves existing request/header timeout behavior until later transport work lands.
  - Timeout configuration is represented by a typed request-scoped structure rather than ad hoc keyword branching.
  - Verification evidence: `test/http_client_tests.jl` passed under a harness shim that defines `_http_windows_ci()`, and `test/http_websocket_client_tests.jl` passed directly after adding handshake timeout plumbing and post-upgrade deadline clearing.

### [x] ITEM-002 (P0) Enforce connect and response-header timeouts across HTTP/1 and HTTP/2
- Description: Today the rewrite only partially applies `connect_timeout`, mostly via `HostResolver`, and does not consistently bound TLS handshake, proxy CONNECT tunneling, HTTP/2 negotiation, or waiting for response headers after the request is sent. Add explicit enforcement for the connection-establishment phase and the response-header phase across both H1 and H2.
- Desired outcome: `connect_timeout` covers DNS/TCP/proxy CONNECT/TLS/HTTP2 setup as one bounded phase, and `response_header_timeout` bounds the period after the request is fully sent until response headers are available.
- Affected files: `src/http_client.jl`, `src/http_transport.jl`, `src/http2_client.jl`, `src/http_proxy.jl`, `test/http_client_transport_tests.jl`, `test/http_client_tests.jl`, `test/http2_client_tests.jl`, `test/http_integration_tests.jl`
- Implementation notes:
  - Refactor the current `_client_for_request(...; connect_timeout=...)` flow so connect deadlines are applied per request/attempt rather than only by creating a special implicit client.
  - Ensure HTTP/1 connection establishment covers direct connect, proxy CONNECT tunnel setup, and TLS handshake under the same phase deadline.
  - Ensure HTTP/2 establishment covers direct connect, proxy CONNECT tunnel setup, TLS handshake/ALPN, client preface write, initial settings exchange, and readiness before stream creation.
  - Add a response-header timeout path that works for both reused and newly established connections, including streamed request uploads.
  - Keep the timeout failure modes explicit and retry policy-aware so deadline-triggered failures do not accidentally become retry loops.
- Verification:
  - `julia --project=. -e 'using Test; using HTTP; using Reseau; _http_windows_ci() = false; include("test/http_client_tests.jl")'`
  - `julia --project=. test/http_client_transport_tests.jl`
  - `julia --project=. test/http_websocket_client_tests.jl`
  - `julia --project=. test/http2_client_tests.jl`
- Assumptions:
  - The connection-establishment timeout should not include full response body download time; that is handled by later phases.
  - `response_header_timeout` begins after request headers/body/trailers are fully committed, except for `Expect: 100-continue` where the dedicated timeout governs the interim wait.
  - Per-request connect timeouts can be implemented by cloning the existing `Transport.host_resolver` with tighter timeout/deadline values instead of allocating a whole new client for explicit-client calls.
  - TLS handshake timeout should be bounded both by transport deadlines and by a cloned `TLS.Config(handshake_timeout_ns=...)` so handshake stalls fail consistently in H1 and H2.
- Risks:
  - H2 setup currently uses blocking waits in several places; missing any of them would leave partial timeout coverage.
  - Tight deadline plumbing can destabilize retry or pooled connection reuse if failure cleanup is incomplete.
- Completion criteria:
  - Connect establishment is bounded consistently for both H1 and H2.
  - Response header waits are bounded consistently for both H1 and H2.
  - Regression tests cover timeout failures in direct, tunneled, and negotiated setups where practical.
  - Verification evidence: targeted H1 client, H1 transport, websocket client, and H2 client suites all passed after adding explicit-client `connect_timeout`, H1/H2 response-header timeouts, and websocket handshake timeout coverage.

### [x] ITEM-003 (P0) Implement read/write inactivity timeouts and overall request deadline semantics
- Description: The rewrite currently uses `readtimeout` as an absolute request deadline in HTTP/1 and does not enforce an equivalent behavior in HTTP/2. Introduce explicit idle/inactivity timeouts for reads and writes, add a separate overall request timeout/deadline, and make those semantics work for request uploads, response body streaming, and multiplexed HTTP/2 streams.
- Desired outcome: Users can independently control overall request lifetime, read inactivity, and write inactivity. The deprecated `readtimeout` keyword maps to read inactivity to preserve the closest existing `master` behavior, while the new overall timeout replaces the current overloaded deadline behavior.
- Affected files: `src/http_client.jl`, `src/http_stream.jl`, `src/http_transport.jl`, `src/http2_client.jl`, `src/http_core.jl`, `test/http_client_tests.jl`, `test/http_client_transport_tests.jl`, `test/http2_client_tests.jl`, `test/http_integration_tests.jl`
- Implementation notes:
  - Add helpers for phase-relative deadlines that refresh after successful read/write progress instead of one absolute deadline reused for every operation.
  - Preserve a distinct overall request deadline for callers who want “entire exchange must finish within N seconds”.
  - Apply read idle timeouts to response-header reads, response-body reads, and relevant HTTP/2 waits for DATA/HEADERS progress.
  - Apply write idle timeouts to request body uploads in both H1 and H2, including the streaming upload path used around `Expect: 100-continue`.
  - Ensure stream and body wrapper paths refresh deadlines on progress rather than only on initial start.
- Verification:
  - `julia --project=. -e 'using Test; using HTTP; using Reseau; _http_windows_ci() = false; include("test/http_client_tests.jl")'`
  - `julia --project=. test/http_client_transport_tests.jl`
  - `julia --project=. test/http_websocket_client_tests.jl`
  - `julia --project=. test/http2_client_tests.jl`
- Assumptions:
  - The closest `HTTP#master` interpretation for `readtimeout` is inactivity between read progress events, not an overall deadline.
  - It is acceptable for the new overall request timeout to use a new name instead of overloading `readtimeout`.
  - Waiting for the first response headers should count as read inactivity when `response_header_timeout` is unset, so `read_idle_timeout` and deprecated `readtimeout` still protect header stalls.
  - For HTTP/2, read/write idle timeouts can be enforced at the stream wait / flow-control layer without imposing a single connection-wide socket read deadline on the shared read loop.
- Risks:
  - Read/write timeout handling in H2 is easy to under-apply because data and wakeups come from a shared background reader task.
  - Streaming APIs may expose races if the timeout clock is not refreshed in the same place where bytes become visible to callers.
- Completion criteria:
  - `readtimeout` now behaves like a deprecated alias for read inactivity.
  - New overall request timeout semantics exist separately and are covered by tests.
  - Read/write idle timeouts work for H1 and H2 request/response flows.
  - Verification evidence: shimmed `http_client_tests.jl`, `http_client_transport_tests.jl`, `http_websocket_client_tests.jl`, and `http2_client_tests.jl` all passed with new H1 read-idle, H2 read-idle, and H2 write-idle regressions.

### [x] ITEM-004 (P1) Round out timeout coverage, defaults, and client-facing documentation/tests
- Description: After the new timeout model exists, the remaining work is to make it feel production-ready: ensure verbose/docstrings/reference text describe the new behavior clearly, apply the appropriate timeout knobs to remaining client surfaces such as websockets, and add a realistic regression matrix around retries, redirects, streaming, and pooled/reused connections.
- Desired outcome: The rewrite exposes a coherent, well-documented timeout interface with regression coverage that reflects real production usage patterns rather than only isolated socket timeouts.
- Affected files: `src/http_client.jl`, `src/http_stream.jl`, `src/http_websockets.jl`, `src/http_client_verbose.jl`, `test/http_client_tests.jl`, `test/http_stream_tests.jl`, `test/http_websocket_client_tests.jl`, `test/http_integration_tests.jl`
- Implementation notes:
  - Update high-level docstrings and any verbose/debug output that mention the old `readtimeout` behavior.
  - Ensure redirects/retries carry forward the new timeout semantics intentionally and do not accidentally reset or ignore them.
  - Validate websocket client behavior for connect/handshake/read inactivity timeouts where those semantics sensibly apply.
  - Add regression tests that exercise pooled connection reuse, redirects, retries, streaming bodies, and websocket handshakes under the new timeout model.
- Verification:
  - `julia --project=. test/http_client_tests.jl`
  - `julia --project=. test/http_websocket_client_tests.jl`
  - `julia --project=. test/http_websocket_integration_tests.jl`
  - `julia --project=. test/http_integration_tests.jl`
  - `julia --project=. test/runtests.jl`
- Assumptions:
  - Documentation changes should stay in code/docstrings; no standalone markdown files should be committed in this pass.
  - Existing intermittent integration flakes, if any, still need to be understood and either avoided or called out explicitly before marking this item done.
- Risks:
  - Redirect/retry reuse can accidentally restart per-attempt timers when we actually want an overall timeout to keep counting down.
  - Websocket timeout semantics overlap with HTTP handshake and long-lived bidirectional I/O, so scope must stay explicit.
- Completion criteria:
  - Public docs/docstrings reflect the new timeout model.
  - Regression coverage exists for the main client surfaces and timing behaviors.
  - Full verification is green, or any remaining unrelated flake is isolated and documented before closing the item.
  - Verification evidence: `julia --project=. test/runtests.jl` passed after the timeout docstring cleanup and the new timeout regressions from the earlier items.

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
