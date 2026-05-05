-- /sys/k/cap.lua — capability checks.
--
-- A capability is a string token granting one privilege. Capabilities are
-- assigned to processes at spawn time (from manifest + per-user grants),
-- stored on the proc record and consulted by:
--   * exec.exec when spawning child processes (syscall:exec, syscall:write)
--   * vfs.open / vfs.write_all on write modes (syscall:write:<glob>)
--   * apps/installers requesting hardware (component:<type>[:addr])
--
-- The `enforce` flag controls behaviour: when false, cap.check always
-- returns true but writes a denial record to the audit log; when true,
-- cap.check returns false on a deny and the caller raises EPERM.

local M = {}

local enforce
local audit                                         -- lazy require to avoid cycles

function M.init(opts)
  enforce = (opts or {}).enforce == true
end

function M.set_enforce(v) enforce = v == true end
function M.is_enforcing() return enforce == true end

local function glob_match(want, pattern)
  local star = pattern:find("*", 1, true)
  if not star then return want == pattern end
  local prefix = pattern:sub(1, star - 1)
  local suffix = pattern:sub(star + 1)
  if want:sub(1, #prefix) ~= prefix then return false end
  if suffix == "" then return true end
  return want:sub(-#suffix) == suffix
end

local function holds(proc_caps, want)
  if not proc_caps then return false end
  if proc_caps["*"] then return true end
  for cap in pairs(proc_caps) do
    if cap == want or glob_match(want, cap) then return true end
  end
  return false
end

function M.check(proc_caps, want, ctx)
  -- ctx: { proc, action } — used for audit; never required for the
  -- algorithmic decision.
  if holds(proc_caps, want) then return true end
  audit = audit or require("lib.auth.audit")
  audit.write({
    kind   = "cap.deny",
    user   = ctx and ctx.user,
    action = want,
    target = ctx and ctx.target,
    detail = ctx and ctx.detail,
  })
  if not enforce then return true end
  return false
end

function M.expand_set(list)
  local set = {}
  for _, c in ipairs(list or {}) do set[c] = true end
  return set
end

return M
