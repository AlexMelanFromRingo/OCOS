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
    cmdline         = opts.cmdline or opts.name or ("proc-" .. seq),
    status          = "new",                     -- new|ready|running|sleeping|waiting|dead
    parent          = opts.parent,
    children        = {},
    caps            = opts.caps or {},
    env             = opts.env,
    io              = opts.io,                   -- {stdin, stdout, stderr} streams
    shell_env       = opts.shell_env,            -- PATH/PWD/USER table
    mailbox         = {},
    exit_code       = nil,
    coroutine       = nil,
    filter          = nil,
    deadline        = nil,
    restart_policy  = opts.restart_policy or "one_shot",
    kv              = {},
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

-- M.pause(pid) / M.resume(pid)
--
-- Pause parks a process by flipping its status to "paused"; the scheduler's
-- is_ready predicate returns false for that, so the coroutine is never
-- resumed even when its filter would otherwise match an incoming event.
-- The prior status is stashed on the proc so resume can restore it. We
-- use this for VT switching: the shell coroutine sits in console.read_line
-- waiting for key_down; pausing it stops it from consuming events while
-- the GUI session is active. Resume restores the prior status; the next
-- matching signal then resumes the coroutine normally.
function M.pause(pid)
  local p = procs[pid]
  if not p then return nil, "no such process" end
  if p.status == "paused" then return true end
  p.kv.paused_from = p.status
  p.status = "paused"
  return true
end

function M.resume(pid)
  local p = procs[pid]
  if not p then return nil, "no such process" end
  if p.status ~= "paused" then return true end
  p.status = p.kv.paused_from or "ready"
  p.kv.paused_from = nil
  return true
end

-- M.kill(pid, sig)
--
--   sig = "term" (default): cooperative shutdown. Publishes ipc
--         "proc.term" with {pid} so the process can clean up, and
--         delivers raw signal "__sigterm__<pid>" via computer.pushSignal
--         so any sched.wait() resumes immediately. Well-behaved
--         processes subscribe to proc.term and exit.
--   sig = "kill": hard dispose. The proc is marked dead, proc.exit is
--         published with exit_code = -9, and the coroutine is dropped
--         on the floor — Lua has no coroutine.throw, so we just stop
--         resuming it and let GC reap the dead coroutine.
--
-- Returns true on success, nil + reason on missing pid.
function M.kill(pid, sig)
  local p = procs[pid]
  if not p then return nil, "no such process" end
  sig = sig or "term"
  if sig == "kill" or sig == 9 or sig == "SIGKILL" then
    p.status = "dead"
    p.exit_code = -9
    local ipc = require("k.ipc")
    ipc.publish("proc.exit", { id = p.id, name = p.name, code = -9, reason = "killed" })
    M.dispose(p)
    return true
  end
  -- Cooperative term path. Don't dispose — the proc decides when to die.
  local ipc = require("k.ipc")
  ipc.publish("proc.term", { pid = pid })
  pcall(computer.pushSignal, "__sigterm__" .. pid)
  p.kv.term_requested = true
  return true
end

return M
