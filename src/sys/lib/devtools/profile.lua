-- /sys/lib/devtools/profile.lua — wall-time micro-benchmarks.
--
-- The OpenComputers sandbox does not expose debug.sethook to user code
-- (it is reserved for the watchdog), so a sampling profiler is not
-- possible. We provide an explicit time-it API instead, sufficient for
-- comparing implementations and tracking per-iteration cost.
--
-- Usage:
--   local prof = require("lib.devtools.profile")
--   local report = prof.bench("sha256(1KB)", 100, function()
--     sha.hex(string.rep("x", 1024))
--   end)
--   print(prof.format({report}))

local M = {}

local function now() return computer.uptime() end

function M.time(fn, ...)
  local args = table.pack(...)
  local start = now()
  fn(table.unpack(args, 1, args.n))
  return now() - start
end

function M.bench(name, iterations, fn)
  local before = now()
  for _ = 1, iterations do fn() end
  local elapsed = now() - before
  return {
    name        = name,
    iterations  = iterations,
    elapsed_s   = elapsed,
    per_iter_ms = elapsed * 1000 / iterations,
  }
end

function M.format(rows)
  local lines = { string.format("%-32s  %8s  %14s  %14s",
    "BENCH", "ITERS", "TOTAL (ms)", "PER ITER (ms)") }
  for _, r in ipairs(rows) do
    lines[#lines + 1] = string.format("%-32s  %8d  %14.2f  %14.4f",
      r.name, r.iterations, r.elapsed_s * 1000, r.per_iter_ms)
  end
  return table.concat(lines, "\n")
end

return M
