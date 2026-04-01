# Trim Task Entrypoint Root Cause Write-Up

Repo/worktree where this investigation was done:
- `/Users/jacob.quinn/.julia/dev/HTTP`

Environment used for the repros below:
- Julia `1.12.5`
- JuliaC `0.3.1`
- macOS `arm64` (`Darwin 24.6.0`)

## Summary

The current HTTP trim-compile blocker appears to be **a trimmed-runtime issue around `Task` entry callables**, not primarily an HTTP bug.

The short version is:

- `Base.Experimental.entrypoint(f, ())` is enough for a **top-level `Main` function** used as `Task(f)` in a trimmed executable.
- The same pattern does **not** work reliably for **package-local task entry functions/callables**.
- Direct package calls still work under trim.
- The failure is specifically when a callable becomes `Task.code` and is later invoked by the trimmed runtime.

This explains the HTTP behavior:

- a script-local task entry in `Main` can run and call into HTTP
- but once HTTP itself tries to spawn its own internal listener/connection tasks from package code, the trimmed executable fails or hangs

### Current Working Assumption

For the current HTTP trim work, treat spawned-task/runtime behavior as a known trimmed-runtime limitation:

- `Threads.@spawn` / `Task(...)` paths may still fail or hang in trimmed executables even after the surrounding code becomes verifier-clean.
- That does **not** make the verifier work pointless; it is still valuable to keep pushing client/server code to be trim-compileable so the remaining gap is isolated to trimmed task/runtime support.
- In practice, a workload being "trim-safe" currently needs to be read in two layers:
  - verifier-clean compileability
  - trimmed-executable runtime behavior, which may still be blocked by the task-entry/runtime issue above

## HTTP Manifestation

In HTTP, the first public high-level path that hits this is the server side.

What we observed:

- a blocking script-local task that calls `HTTP.serve(...)` can start
- but the true internal server async path still breaks in trimmed runtime
- when exercising the real `serve!` path, the trimmed executable fails with a package-local task entry error of the form:

```text
Base.TaskFailedException(... MethodError(f=HTTP._ServeTCPListenerTaskEntry(), args=()))
```

Earlier versions of the investigation also showed hangs where the client could write the request but never receive a response because the internal package-local listener task never actually began serving.

## Why This Looks Like a Core Trim/Runtime Issue

The key point is that the failure reproduces in tiny standalone examples outside HTTP.

Two important observations:

1. `Base.Experimental.entrypoint(f, ())` in Base currently just roots:

```julia
Tuple{Core.Typeof(f)}
```

from:

```julia
function entrypoint(f, argtypes::Tuple)
    entrypoint(Tuple{Core.Typeof(f), argtypes...})
end
```

2. Direct package function calls survive trim, but package-local task entry callables do not.

That strongly suggests the problem is not “package functions are removed by trim”.

It appears to be specifically about how the trimmed runtime preserves and later invokes the callable object stored in `Task.code`.

## Minimal Repro Matrix

### Repro A: `Main` top-level named task entry works

This succeeds in a trimmed executable.

```julia
function plain_entry()::Nothing
    return nothing
end

Base.Experimental.entrypoint(plain_entry, ())

function @main(args::Vector{String})::Cint
    _ = args
    t = errormonitor(Task(plain_entry))
    schedule(t)
    wait(t)
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
```

Observed result:
- trim compile succeeds
- trimmed executable exits `0`

### Repro B: package-local direct call works

This also succeeds in a trimmed executable.

`TaskEntryPkg3/src/TaskEntryPkg3.jl`:

```julia
module TaskEntryPkg3

function plain_entry()::Nothing
    return nothing
end

Base.Experimental.entrypoint(plain_entry, ())

end
```

Runner:

```julia
using TaskEntryPkg3

function @main(args::Vector{String})::Cint
    _ = args
    TaskEntryPkg3.plain_entry()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
```

Observed result:
- trim compile succeeds
- trimmed executable exits `0`

### Repro C: package-local top-level named task entry fails

This is the key minimal failing case.

`TaskEntryPkg2/src/TaskEntryPkg2.jl`:

```julia
module TaskEntryPkg2

function plain_entry()::Nothing
    return nothing
end

Base.Experimental.entrypoint(plain_entry, ())

end
```

Runner:

```julia
using TaskEntryPkg2

function @main(args::Vector{String})::Cint
    _ = args
    t = errormonitor(Task(TaskEntryPkg2.plain_entry))
    schedule(t)
    wait(t)
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
```

Observed result:
- trim compile succeeds
- trimmed executable fails at runtime with:

```text
Base.TaskFailedException(
    task=Core.Task(...,
        result=Core.MethodError(
            f=TaskEntryPkg2.var"#plain_entry"(),
            args=(),
            world=...
        ),
        code=TaskEntryPkg2.var"#plain_entry"(),
        ...
    )
)
```

This is the strongest evidence that the problem is about package-local task entry callables in trimmed runtime, not about package functions generally.

### Repro D: `Main` closure task entry also fails

This is also useful because it shows the issue is broader than just package modules.

`TaskEntryPkg4/src/TaskEntryPkg4.jl`:

```julia
module TaskEntryPkg4

function plain_entry()::Nothing
    return nothing
end

Base.Experimental.entrypoint(plain_entry, ())

end
```

Runner:

```julia
using TaskEntryPkg4

function main_wrapped_task()::Nothing
    t = errormonitor(Task(() -> TaskEntryPkg4.plain_entry()))
    schedule(t)
    wait(t)
    return nothing
end

Base.Experimental.entrypoint(main_wrapped_task, ())

function @main(args::Vector{String})::Cint
    _ = args
    main_wrapped_task()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
```

Observed result:
- trim compile succeeds
- trimmed executable fails at runtime with:

```text
Base.TaskFailedException(... MethodError(f=Main.var"#main_wrapped_task##..."(), args=()))
```

So closures used as `Task.code` are also not trim-safe here.

## What This Suggests

The current working hypothesis is:

- trim preserves direct callable method entrypoints well enough for ordinary direct calls
- but when a callable object is stored into `Task.code` and later invoked by the scheduler/runtime, certain callable shapes are not preserved correctly
- the only shape we have confirmed to work is:
  - top-level named function
  - defined in `Main`
  - passed directly as `Task(f)`

The failing shapes we have confirmed are:
- package-local named function used as `Task(pkgfunc)`
- `Main` closure used as `Task(() -> ...)`
- package-local callable singleton object used as `Task(callable_object)` in HTTP experiments

## Why This Matters For HTTP

HTTP’s production server/client internals use internal background tasks.

If package-local task entry callables are not trim-safe, then high-level public APIs like:
- `HTTP.serve!`
- `HTTP.listen!`
- likely websocket server loops
- likely any other internal background task path

will remain blocked in trimmed executables even if normal Julia runtime behavior is correct.

That means this is not something HTTP can responsibly “paper over” with shortcuts without compromising the package design and goals.

## Suggested Questions For Core Devs

1. Is the current trim model expected to support package-local task entry functions used as `Task(pkgfunc)`?
2. Is the runtime `Task.code` invocation path expected to require more than `Base.Experimental.entrypoint(f, ())`?
3. Is this a known limitation specific to:
   - package-local functions
   - closures
   - callable singleton objects
   when used as `Task.code`?
4. Is there an intended trim-safe pattern for package-internal async/background tasks besides moving task entrypoints into `Main`?
5. If this is a compiler/runtime bug, should the minimal repro above be filed against Julia or JuliaC?

## How To Present The Issue Succinctly

One-sentence version:

> In a trimmed executable, `Task(f)` works for a top-level named function in `Main`, but the same rooted pattern fails at runtime for package-local task entry functions/callables, even though direct package calls still work.

That seems to be the core issue blocking true high-level HTTP server trim coverage.
