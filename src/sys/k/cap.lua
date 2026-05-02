-- /sys/k/cap.lua — capability checks. Stubbed in M1 (logs but does not block).
--
-- Future: enforce per-process capability sets at component proxy creation,
-- file writes, and IPC publishes. For now we just record requests so other
-- code can use the same API and we have a migration path.

local M = {}

local enforce

function M.init(opts)
  enforce = (opts or {}).enforce == true
end

function M.check(proc_caps, want)
  if not enforce then return true end
  if not proc_caps then return false end
  if proc_caps["*"] then return true end
  if proc_caps[want] then return true end
  -- prefix wildcards: caps may contain entries like "component:filesystem:*"
  for cap in pairs(proc_caps) do
    if cap:sub(-2) == ":*" and want:sub(1, #cap - 1) == cap:sub(1, -2) then
      return true
    end
  end
  return false
end

function M.expand_set(list)
  -- Convert an array of cap strings to a set table.
  local set = {}
  for _, c in ipairs(list or {}) do set[c] = true end
  return set
end

return M
