-- /sys/k/proc.lua — process bookkeeping.
--
-- A process is a plain table:
--   { id, name, status, parent, children, caps, env, mailbox, exit_code,
--     coroutine, filter, deadline, restart_policy, kv }
-- All scheduler state lives in these tables (no closure capture of live
-- coroutines). The scheduler is the only writer of `status` and `coroutine`.

local M = {}

local procs                                      -- {id -> proc}
local by_co                                      -- {coroutine -> proc}
local seq

function M.init()
  procs = {}
  by_co = setmetatable({}, { __mode = "k" })     -- weak keys: GC reaps stale
  seq = 0
end

function M.create(opts)
  seq = seq + 1
  local p = {
    id              = seq,
    name            = opts.name or ("proc-" .. seq),
    status          = "new",                     -- new|ready|running|sleeping|waiting|dead
    parent          = opts.parent,
    children        = {},
    caps            = opts.caps or {},
    env             = opts.env,
    mailbox         = {},
    exit_code       = nil,
    coroutine       = nil,
    filter          = nil,                       -- function(name, ...) -> bool
    deadline        = nil,                       -- uptime() value to wake at
    restart_policy  = opts.restart_policy or "one_shot",
    kv              = {},                        -- per-process scratch
  }
  procs[p.id] = p
  if opts.parent and procs[opts.parent.id] then
    procs[opts.parent.id].children[p.id] = p
  end
  return p
end

function M.attach_coroutine(p, co)
  p.coroutine = co
  by_co[co] = p
end

function M.find_by_coroutine(co)
  return by_co[co]
end

function M.get(id)  return procs[id] end
function M.list()
  local out = {}
  for _, p in pairs(procs) do out[#out + 1] = p end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function M.dispose(p)
  if p.parent and procs[p.parent.id] then
    procs[p.parent.id].children[p.id] = nil
  end
  for _, ch in pairs(p.children) do ch.parent = nil end
  by_co[p.coroutine] = nil
  procs[p.id] = nil
end

return M
