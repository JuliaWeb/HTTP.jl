# Deterministic test synchronization

HTTP.jl tests must not depend on scheduler speed or elapsed wall-clock time.
GitHub Actions runners can pause a task for an unknown period. A delay that is
safe on one runner can fail on another runner without a product defect.

Use observable state transitions instead:

- Use a `Channel`, `Base.Event`, or `Threads.Condition` for task handshakes.
- Read exact byte counts, complete protocol frames, markers, or EOF.
- Use `fetch(task)` or `wait(task)` for task completion. Wrap unexpected
  `Threads.@spawn` failures with `errormonitor`.
- Inject a fixed clock value into pure deadline calculations.
- Use an already-expired absolute deadline when a test must enter a product
  timeout branch. Do not wait for a future deadline to expire.
- Mutate private lifecycle state only when the test directly covers that state,
  such as an idle-pool eviction test.

Do not use `sleep`, `timedwait`, `time`, `time_ns`, `Timer`, elapsed-time
assertions, polling intervals, or helper-level timeout arguments in test code.
Do not use a short delay to prove that an event has not occurred. Build a
barrier that makes the event impossible until the test releases it.

Product timeout configuration remains valid test input. It tests parsing,
propagation, and expired-deadline behavior. It must not act as the test harness.
The GitHub Actions job timeout remains the final guard for a true deadlock.
