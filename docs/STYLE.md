# OCOS Lua style

Short, opinionated. Read once before opening a PR.

## Modules

* Every module starts with a header comment that documents its purpose
  and public API in three to five sentences.
* The first lines after the header are `local M = {}` and the requires.
* Public functions live on `M`; everything else is `local`.
* The last line is `return M`.

## Naming

* `snake_case` for variables, parameters, and local functions.
* `PascalCase` only for prototype-class tables (e.g. `local Stream = {}`).
* Constants are `UPPER_SNAKE_CASE` if they're truly constant.
* No leading underscore prefixes except `_G`, `_ENV`, and the
  `_OSVERSION` / `_OCOS` globals defined by the boot.

## Errors

* Validate at boundaries, return `nil, err`. Don't `assert` user input.
* Use `assert` for invariants that should be impossible to violate; the
  message should help a future contributor diagnose the regression.
* `error()` only when the caller cannot reasonably recover and a
  traceback is the right output (kernel panic, sandbox violation).

## Coroutines

* Never call `computer.pullSignal` from outside the scheduler. Use
  `sched.wait`, `sched.sleep`, `sched.wait_pid`.
* Never call `coroutine.yield` directly from a process — that's what
  the sched API is for.
* If a closure captures a live coroutine, refactor: state belongs in
  plain tables for Eris persistence safety.

## Resource budgets

* The OC GPU has a per-tick op limit. UI code renders into the Lua-level
  buffer (`lib/ui/buffer`) which diff-flushes — never call `gpu.set` in
  a tight loop on user input.
* The 5-second deadline is real. CPU-bound work must yield at least
  once a second via `sched.sleep(0)`.

## Comments

* Document **why**, not **what**. The function name should answer the
  what.
* Inside functions, comments are usually unnecessary — if you need them,
  consider a helper function instead.
* No "M2 will fix this" comments. Implement now or omit the surface.
