# Action Items: HTTP compile workloads

## Context
- Repo: HTTP.jl
- Worktree: /Users/jacob.quinn/.julia/dev/HTTP
- Branch: codex/http-2.0-extraction

## Scope Note
- The precompile pass is complete and committed. This pass resumes the deferred trim-compile work.
- The trim goal is a production-grade JuliaC `--trim=safe` workload suite that exercises the package through normal entrypoints wherever possible, with no OS-specific trim branches, no silent verifier slop, and no “cheating” through internals beyond the deliberately temporary bootstrap workload used to find the first higher-layer verifier blocker.
- Per the current plan, we will start from the lowest viable full server/request exchange, get that trim-safe, then progressively replace internals with higher layers until we hit the first real verifier wall. At that point we will stop, capture the exact blocker, and review next steps before broadening the rest of the matrix.

## Items

### [x] ITEM-001 (P0) Add a real package precompile workload
- Description: The branch currently has no package-integrated precompile workload. `HTTP#master` already uses `PrecompileTools`, but this rewrite does not include any end-user precompile path. We need a production-grade workload that exercises the main public HTTP entrypoints on loopback without relying on internals or OS-specific special cases.
- Desired outcome: Package precompilation runs a stable, high-level workload that covers representative core functionality through public APIs and improves first-use latency for real users.
- Affected files: `Project.toml`, `src/HTTP.jl`, `src/precompile.jl`
- Implementation notes:
  - Add `PrecompileTools` as a package dependency with appropriate compat.
  - Follow the broad shape of `HTTP#master`'s precompile inclusion, but avoid `localhost` DNS gating by using explicit loopback addresses and local servers.
  - Build the workload around exported entrypoints such as `HTTP.serve!`, `HTTP.get`/`HTTP.post`, `HTTP.open`, `HTTP.Router`, `HTTP.fileserver`, and a public HTTP/2 client/server roundtrip if stable.
  - Keep the workload safe for package precompilation: local only, no external network, no platform-specific branches, and careful cleanup of client/server resources.
- Verification:
  - `julia --project=. -e 'using HTTP'`
  - `julia --project=. -e 'using HTTP; @assert HTTP.VERSION == v"2.0.0"'`
  - `julia --project=. test/runtests.jl`
- Assumptions:
  - `PrecompileTools` is acceptable to add on this branch because `HTTP#master` already depends on it.
  - A cleartext loopback H2 workload is more robust here than a TLS-based precompile workload.
  - Cleanup needs to explicitly quiesce `Reseau.IOPoll` after local client/server workload execution so package precompilation exits cleanly.
- Completion criteria:
  - `src/precompile.jl` exists and is included during package precompilation.
  - The workload is built from public/exported HTTP APIs instead of direct internal parser/framer calls.
  - The package loads cleanly and the full test suite still passes.
- Verification evidence:
  - `julia --project=. -e 'using HTTP; @assert HTTP.VERSION == v"2.0.0"; println("using-ok")'`
  - `julia --project=. -e 'using Pkg; Pkg.precompile()'`
  - `julia --project=. test/runtests.jl`

### [x] ITEM-002 (P0) Broaden the precompile workload around normal public flows
- Description: The initial package precompile workload is a solid starting point, but it still leans on some lower-level body helpers and it does not yet cover several of the main public APIs we want users to benefit from immediately. We need to make the workload feel more like ordinary package usage while broadening feature coverage.
- Desired outcome: Package precompilation runs a richer, user-shaped loopback workload that exercises the main exported client/server/protocol entrypoints and avoids unnecessary under-the-hood shortcuts.
- Affected files: `src/HTTP.jl`, `src/precompile.jl`, `src/precompile_workload.jl`
- Implementation notes:
  - Move the workload into a shared internal helper file so the feature matrix stays in one place.
  - Keep the workload loopback-only and explicit about proxy behavior (`ProxyConfig()`) so environment proxy settings do not shape precompile behavior.
  - Broaden the workload to cover representative public flows such as:
    - top-level request helpers on `String`/`URI`
    - reusable `Client` + `Transport`
    - `Router`, `register!`, and `handlertimeout`
    - redirects and cookies
    - `HTTP.open`
    - `response_stream = IOBuffer()`
    - `servecontent` range handling and `fileserver`
    - one public HTTP/2 client/server flow
    - one public WebSocket echo flow
  - Continue to avoid external networking and OS-specific branches.
- Verification:
  - `julia --project=. -e 'using Pkg; Pkg.precompile()'`
  - `julia --project=. test/http_precompile_workload_tests.jl`
  - `julia --project=. test/runtests.jl`
- Assumptions:
  - Sharing a single internal workload helper between package precompilation and tests is acceptable because the workload itself is built from public HTTP APIs.
  - Request-handler request-body reads may still need the exported `body_read!` API because there is not yet a higher-level request-body convenience surface in request handlers.
- Completion criteria:
  - The precompile workload covers the agreed public feature matrix through normal loopback roundtrips.
  - The workload does not depend on environment proxy settings or OS-specific branches.
  - Package precompilation and the precompile-related runtime verification remain green.
- Verification evidence:
  - `julia --project=. -e 'using Pkg; Pkg.precompile()'`
  - `julia --project=. test/http_precompile_workload_tests.jl`
  - `julia --project=. test/http_integration_tests.jl`

### [x] ITEM-003 (P0) Add a runtime regression test for the shared precompile workload
- Description: The package precompile workload is valuable partly because it gives us a high-level end-to-end smoke signal during development. Right now that signal only exists indirectly through `Pkg.precompile()`. We should add a focused runtime test that exercises the same shared workload directly.
- Desired outcome: The precompile workload doubles as a normal high-level smoke test, so regressions in the core public workflows are caught quickly even outside explicit package precompile runs.
- Affected files: `test/http_precompile_workload_tests.jl`, `test/runtests.jl`, `src/precompile_workload.jl`
- Implementation notes:
  - Add a focused test file that invokes the shared precompile workload helper directly and treats any thrown error as a regression.
  - Keep the test high-level; it should not rebuild protocol objects manually or bypass the public request/server/WebSocket surfaces.
  - Wire the test into `runtests.jl` in the normal suite order without changing the existing trim-compile wiring yet.
- Verification:
  - `julia --project=. test/http_precompile_workload_tests.jl`
  - `julia --project=. test/runtests.jl`
- Assumptions:
  - Running the shared workload in the normal suite is acceptable so long as cleanup remains robust and loopback-only.
- Completion criteria:
  - There is a dedicated test file for the shared precompile workload.
  - The normal suite runs it successfully without special harness gymnastics.
  - The package precompile workload and runtime smoke path stay aligned.
- Verification evidence:
  - `julia --project=. test/http_precompile_workload_tests.jl`
  - `julia --project=. test/http_integration_tests.jl`
  - `julia --project=. test/runtests.jl` now runs cleanly through `http_precompile_workload_tests.jl`; the only remaining failure is the intentionally deferred `trim_compile_tests.jl` item.

### [x] ITEM-004 (P0) Establish the lowest viable trim-safe full exchange
- Description: The current trim workload suite starts too high and already runs into client-side trim issues. To make progress cleanly, we need a bootstrap workload that exercises a real local accept/request/response exchange through the thinnest viable server/client path, even if that means temporarily using internal layers to identify the first trim-safe baseline.
- Desired outcome: We have one trim workload that compiles and runs under JuliaC `--trim=safe` with zero verifier errors and executes a complete HTTP exchange end to end.
- Affected files: `test/trim_compile_tests.jl`, `test/trim_workload_common.jl`, `test/http_trim_client_server.jl`, and whichever minimal HTTP source files require trim-safety fixes discovered during investigation
- Implementation notes:
  - Start lower than `HTTP.request`/`HTTP.open`; use the smallest full exchange path that still does real socket accept + request + response work.
  - Keep the workload loopback-only and deterministic.
  - Fix trim-safety issues in package code only when they are genuinely required for this minimal exchange to compile/run; avoid speculative refactors.
  - Tighten the trim harness enough that a missing verifier summary is treated as a failure, not silent success, for the workloads we actively rely on.
- Verification:
  - `HTTP_TRIM_ONLY=http_trim_client_server.jl julia --project=. test/trim_compile_tests.jl`
- Assumptions:
  - A small amount of temporary internal usage is acceptable only for this bootstrap item, because the explicit goal is to establish the first trim-safe baseline before climbing back toward public entrypoints.
- Completion criteria:
  - One trim workload compiles with zero verifier errors and zero warnings tolerated.
  - The produced executable runs successfully.
  - The workload performs a real loopback HTTP exchange rather than just isolated parser/framer calls.
- Verification evidence:
  - `julia --project=. test/http_trim_client_server.jl`
  - `HTTP_TRIM_ONLY=http_trim_client_server.jl julia --project=. test/trim_compile_tests.jl`

### [ ] ITEM-005 (P0) Climb from the bootstrap exchange to the first higher-layer verifier blocker
- Description: Once the lowest-layer exchange is trim-safe, we need to progressively replace internal usage with higher-level package entrypoints until we find the first concrete trim verifier failure. That blocker should become the next design target instead of continuing to guess broadly.
- Desired outcome: We can name the highest currently trim-safe layer in the client/server stack, and we have the exact verifier error that appears at the next layer up.
- Affected files: `test/http_trim_client_server.jl`, `test/http_trim_open_fileserver.jl`, `test/http_trim_http2.jl`, `test/http_trim_websocket.jl`, `test/trim_workload_common.jl`, and any directly implicated HTTP source files
- Implementation notes:
  - Replace the bootstrap internals incrementally, one layer at a time.
  - After each step, rerun the targeted trim workload instead of batching multiple jumps together.
  - Stop at the first higher-layer verifier error rather than tunneling through it blindly in this item.
  - Capture the exact failing workload, layer boundary, and verifier output in the tracker before moving on.
- Verification:
  - `HTTP_TRIM_ONLY=http_trim_client_server.jl julia --project=. test/trim_compile_tests.jl`
  - `HTTP_TRIM_ONLY=http_trim_open_fileserver.jl julia --project=. test/trim_compile_tests.jl`
- Assumptions:
  - The first blocker may be in public client kw dispatch, default client construction, proxy defaults, or streamed response typing based on earlier exploratory results.
- Completion criteria:
  - The current highest trim-safe layer is identified and working.
  - The first next-layer verifier failure is reproduced on demand.
  - The exact verifier error and implicated code path are recorded clearly enough for the next pass.
- Current investigation note:
  - Highest currently confirmed trim-safe layer: `HTTP.serve!(handler, listener)` now trim-compiles with zero verifier errors after switching listener-address formatting onto concrete `SocketAddrV4`/`SocketAddrV6` branches and the new `Reseau` `string(::SocketAddrV4/6)` helpers.
  - The original `serve!(handler, listener)` verifier blocker in `src/http_server.jl:_listener_bound_address(listener::TCP.Listener)` is resolved.
  - The current next blocker is runtime-only: the compiled `http_trim_client_server` executable still hangs during shutdown after a successful `serve!(handler, listener)` exchange, even when the workload calls `forceclose(server)`, `wait(server)`, closes client/listener handles, and shuts down `Reseau.IOPoll`.
  - After isolating around the known package-internal task limitation, the next higher-layer blocker on the client side is now clearer as well: a simple top-level `HT.get("http://127.0.0.1:port/hello"; proxy=HT.ProxyConfig(), protocol=:h1, ...)` against a `Main`-rooted one-shot server task fails trim verification before runtime.
  - The first concrete public-client verifier error is the kw-wrapper dispatch in `src/http_client.jl`:
    - `Verifier error: unresolved call from statement HTTP.:(var"#request#187")(...)::Response{Vector{UInt8}}`
  - Additional public-client probe failures stack on top of that first blocker for `HT.get(::URI)`, `HT.request(...; response_stream=IOBuffer())`, and `HT.open(...)`, but those are currently treated as downstream noise until the base `HT.get(::String; ...)` path is trim-safe.

### [ ] ITEM-006 (P1) Remove OS-specific trim harness behavior and align the suite with the production bar
- Description: The trim harness still contains OS-specific timeout/bundle defaults and overly forgiving verifier parsing. That violates the desired “no OS-specific trim branches” rule and weakens the signal from the suite.
- Desired outcome: The trim harness is deterministic across platforms, has no OS-conditional trim behavior, and treats verifier output strictly.
- Affected files: `test/trim_compile_tests.jl`
- Implementation notes:
  - Remove OS-specific defaults for bundle mode, executable timeout, and error budget.
  - Make missing verifier summaries and unexpected verifier warnings explicit failures.
  - Keep any remaining environment tuning opt-in and uniform across platforms.
- Verification:
  - `julia --project=. test/trim_compile_tests.jl`
- Assumptions:
  - This item should be done only after at least one real trim workload is passing, so harness strictness does not mask unrelated package issues.
- Completion criteria:
  - There are no OS-specific trim branches left in the harness.
  - The harness fails loudly on malformed or missing verifier output.
  - The targeted trim workloads still run under the stricter harness.

### [ ] ITEM-007 (P1) Expand trim-safe workloads back to the public feature matrix
- Description: After the first higher-layer blocker is understood and the harness is strict, we still need to bring the trim suite up to the same public-facing quality bar as the precompile workload suite: normal request helpers, `HTTP.open`, fileserver/static serving, HTTP/2, and WebSockets.
- Desired outcome: The trim suite covers the main package entrypoints through public workflows, with no under-the-hood shortcuts left.
- Affected files: `test/http_trim_client_server.jl`, `test/http_trim_open_fileserver.jl`, `test/http_trim_http2.jl`, `test/http_trim_websocket.jl`, `test/trim_workload_common.jl`, `test/trim_compile_tests.jl`, and implicated HTTP source files
- Implementation notes:
  - Replace the temporary bootstrap internals with public surfaces once the blocking trim issue is fixed.
  - Keep workloads small and loopback-only, but shaped like real user flows.
  - Verify both compilation and executable runs for each workload.
- Verification:
  - `julia --project=. test/trim_compile_tests.jl`
- Assumptions:
  - Some workloads may need to be introduced or retired based on the exact trim blockers found in ITEM-005.
- Completion criteria:
  - The trim workload suite covers the main agreed package entrypoints.
  - The workloads use public/exported functionality rather than internal shortcuts.
  - The suite runs cleanly with strict verifier handling and no OS-specific trim logic.

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
