# Action Items: Server Middleware and Static Content Pass

## Context
- Repo: HTTP.jl
- Worktree: /Users/jacob.quinn/.julia/dev/HTTP
- Branch: codex/http-2.0-extraction

## Items

### [x] ITEM-002 (P0) `servecontent` With Conditionals and Single-Range Support
- Description: Add a `ServeContent`-style response builder for seekable or byte-backed content. The rewrite currently has no built-in conditional caching or range-serving primitive, which leaves a large gap relative to Go’s production-grade server surface. We need a reusable core that handles MIME inference, `Last-Modified`, caller-supplied `ETag`, RFC 7232 preconditions, and single-range `206`/`416` behavior.
- Desired outcome: `HTTP.servecontent(req, source; ...)` can return correct `200`, `206`, `304`, `412`, and `416` responses for in-memory bytes and seekable file-like content, including `HEAD` suppression.
- Affected files: `src/http_core.jl`, `src/http_server.jl`, `src/http_handlers.jl`, `src/http_sniff.jl`, `src/HTTP.jl`, `test/http_server_http1_tests.jl`, `test/http2_server_tests.jl`
- Implementation notes:
  - Define a streaming body type for ranged or full seekable content so large responses do not need buffering.
  - Implement conditional evaluation in the same precedence order Go uses for `If-Match`, `If-Unmodified-Since`, `If-None-Match`, `If-Modified-Since`, and `If-Range`.
  - Support single `Range: bytes=...` requests first, with correct `Content-Range`, `Accept-Ranges`, and `Content-Length`.
  - Use file extension or sniffing when `content_type` is not supplied.
  - Keep the error-path header behavior simple and explicit instead of copying Go’s legacy compatibility quirks.
- Verification:
  - `julia --project=. test/http_server_http1_tests.jl`
  - `julia --project=. test/http2_server_tests.jl`
- Assumptions:
  - Single-range support is sufficient for this pass; multipart/byteranges can be deferred.
  - The public API may require explicit `etag`/`modtime` inputs instead of automatic hashing or metadata extraction.
- Risks:
  - Conditional precedence bugs are easy to miss without direct tests for each header family.
  - Range support must honor `HEAD` and status-body suppression rules without sending malformed bodies.
- Completion criteria:
  - Conditionals behave correctly for both `GET` and `HEAD`.
  - Valid single-range requests return `206`; invalid/non-overlapping ranges return `416`.
  - The implementation streams large content rather than materializing it eagerly.
- Verification evidence:
  - `julia --project=. test/http_server_http1_tests.jl`
  - `julia --project=. test/http2_server_tests.jl`

### [x] ITEM-003 (P1) `servefile` and `fileserver` on Top of `servecontent`
- Description: Build the higher-level static-serving API once `servecontent` exists. The rewrite has no equivalent to Go’s `ServeFile` / `FileServer`, so users lack a standard rooted static handler with canonical redirects and safe path handling. We need a focused, production-usable static file layer built on the new conditional/range core.
- Desired outcome: `HTTP.servefile(req, path; ...)` and `HTTP.fileserver(root; ...)` exist, stream content through `servecontent`, reject traversal, handle slash canonicalization predictably, and provide a sensible rooted static handler story for common apps.
- Affected files: `src/http_server.jl`, `test/http_server_http1_tests.jl`, `test/http2_server_tests.jl`
- Implementation notes:
  - Add a rooted path resolver that validates and canonicalizes request paths before opening files.
  - Keep directory listing out of scope by default; only serve files and optional index files.
  - Implement canonical redirect behavior for trailing slashes and `/index.html` in a controlled Julia-native way.
  - Reuse `servecontent` for MIME, conditional, and range handling instead of duplicating logic.
  - Decide method behavior up front: likely serve only `GET` and `HEAD`, return `405` otherwise.
- Verification:
  - `julia --project=. test/http_server_http1_tests.jl`
  - `julia --project=. test/http2_server_tests.jl`
- Assumptions:
  - Directory listings remain disabled for this pass.
  - A rooted filesystem handler is more important than matching every Go redirect edge case exactly.
- Risks:
  - Path normalization and percent-decoding bugs can become traversal bugs.
  - Redirect behavior needs to stay consistent across request-handler and router usage.
- Completion criteria:
  - Static file helpers stream real files correctly.
  - Traversal attempts are rejected.
  - Canonical slash/index handling and `GET`/`HEAD` semantics are covered by tests.
- Verification evidence:
  - `julia --project=. test/http_server_http1_tests.jl`
  - `julia --project=. test/http2_server_tests.jl`

### [x] ITEM-004 (P1) Request-Handler Timeout Middleware
- Description: Add a `TimeoutHandler`-style middleware for ordinary `Request -> Response` handlers. Go provides a strong handler-level timeout abstraction; our rewrite currently only has server-wide socket deadlines and request/client timeouts, not per-handler wall-clock limits. We need a request-handler middleware that races handler execution against a deadline and returns `503` with a configured body when the handler exceeds it.
- Desired outcome: `HTTP.handlertimeout(timeout_s; ...)` exists for request handlers, times out predictably with `503`, leaves the server usable afterward, and does not require stream-handler buffering in this pass.
- Affected files: `src/http_core.jl`, `src/http_server.jl`, `src/http_handlers.jl`, `src/HTTP.jl`, `test/http_server_http1_tests.jl`, `test/http2_server_tests.jl`
- Implementation notes:
  - Start with request-handler middleware only; do not expand to stream handlers in this pass.
  - Derive a child request context for timed handlers and cancel it on timeout so downstream code can observe cancellation.
  - Race the handler task against a timer and return a synthetic timeout response when the timer wins.
  - Make sure the middleware does not corrupt later requests on the same connection and documents that streaming response bodies returned after handler completion are outside the timeout window for now.
- Verification:
  - `julia --project=. test/http_server_http1_tests.jl`
  - `julia --project=. test/http2_server_tests.jl`
  - `julia --project=. test/http_handlers_tests.jl`
  - `julia --project=. test/runtests.jl`
- Assumptions:
  - Request-handler timeout semantics only need to bound handler computation through `Response` creation, not the later consumption of a returned streaming body.
  - It is acceptable to defer stream-handler timeout buffering and response-recorder machinery.
- Risks:
  - Late-finishing handler tasks must not leak unhandled exceptions or mutate shared state after a timeout response has already been sent.
  - Cancellation signals may not interrupt every kind of body read yet, so tests should focus on the request-handler contract we can guarantee today.
- Completion criteria:
  - Slow handlers reliably return `503` with the configured timeout body.
  - Fast handlers are unaffected.
  - Full package tests pass after the last item.
- Verification evidence:
  - `julia --project=. test/http_handlers_tests.jl`
  - `julia --project=. test/http_server_http1_tests.jl`
  - `julia --project=. test/http2_server_tests.jl`
  - `julia --project=. test/runtests.jl`

## Continuity

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
