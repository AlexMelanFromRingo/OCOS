-- /sys/k/sched.lua — cooperative scheduler.
--
-- Public API:
--   sched.init()
--   sched.spawn(fn, opts) -> proc       create + queue a process
--   sched.current() -> proc             currently running process
--   sched.sleep(seconds)                yield until timeout
--   sched.wait(filter, timeout) -> ev   yield until event matches filter
--   sched.exit(code)                    terminate current process
--   sched.run()                         main loop, called once by boot
--   sched.shutdown()                    request graceful shutdown
--
-- The scheduler keeps state in plain tables; coroutines are referenced via
-- weak keys in proc bookkeeping so persistence does not strand them.

local M = {}

local proc_mod = require("k.proc")
local signal   = require("k.signal")
local ipc      = require("k.ipc")
local log      = require("k.log")

local ready                                      -- list of proc ids ready to run
local current_proc
local shutdown_requested
local last_proc_id

local function is_ready(p)
  if p.status == "ready"   then return true end
  if p.status == "sleeping" and p.deadline and computer.uptime() >= p.deadline then
    return true
  end
  return false
end

local function compute_wait()
  -- Return the number of seconds to wait in pullSignal:
  --   0    if any process is immediately ready
  --   t>0  if some process has the closest sleep deadline
  --   1    default tick if nothing is sleeping (still want to drain signals)
  for _, p in ipairs(proc_mod.list()) do
    if p.status == "ready" then return 0 end
  end
  local best = math.huge
  for _, p in ipairs(proc_mod.list()) do
    if p.status == "sleeping" and p.deadline then
      best = math.min(best, p.deadline - computer.uptime())
    end
  end
  if best == math.huge then return 1 end
  return math.max(0, best)
end

local function dispatch_event(name, ...)
  -- Translate one OC signal into one IPC publish. Plain table payload so it
  -- survives Eris, no live functions.
  local args = table.pack(...)
  signal.publish(name, ...)
  for _, p in ipairs(proc_mod.list()) do
    if p.status == "waiting" and p.filter and p.filter(name, table.unpack(args, 1, args.n)) then
      p.status = "ready"
      p.kv.last_event = { name = name, args = args }
      p.filter = nil
    end
  end
end

local function resume_proc(p)
  current_proc = p
  p.status = "running"
  local ok, val = coroutine.resume(p.coroutine, p.kv.last_event)
  current_proc = nil
  p.kv.last_event = nil
  if not ok then
    log.error("sched", "process " .. p.name .. " (" .. p.id .. ") crashed: " .. tostring(val))
    p.status = "dead"
    p.exit_code = -1
    ipc.publish("proc.exit", { id = p.id, name = p.name, code = -1, reason = tostring(val) })
    proc_mod.dispose(p)
  elseif coroutine.status(p.coroutine) == "dead" then
    p.status = "dead"
    p.exit_code = p.exit_code or 0
    log.debug("sched", "process " .. p.name .. " (" .. p.id .. ") exited code=" .. tostring(p.exit_code))
    ipc.publish("proc.exit", { id = p.id, name = p.name, code = p.exit_code })
    proc_mod.dispose(p)
  end
  -- if the coroutine yielded, the yield handler below has already updated p
end

-- ---- yield request handling ---------------------------------------------
-- A process yields a request table to the scheduler: { kind = "sleep|wait|exit", ... }
-- We catch that by calling coroutine.resume and inspecting the yielded value.
-- Implementation: sched.sleep / sched.wait / sched.exit yield such tables and
-- the kernel pulls them off via coroutine return values. But coroutine.resume
-- gives us (true, value) on yield. So we redesign: each helper does:
--   local req = { kind="sleep", deadline=... }
--   coroutine.yield(req)                     -- scheduler reads this
--   return ev_after_resume

local function process_yield(p, req)
  if type(req) == "table" then
    if req.kind == "sleep" then
      p.status = "sleeping"
      p.deadline = req.deadline
    elseif req.kind == "wait" then
      p.status = "waiting"
      p.filter = req.filter
      p.deadline = req.deadline                  -- nil for unbounded
    elseif req.kind == "exit" then
      p.status = "dead"
      p.exit_code = req.code or 0
      log.debug("sched", "process " .. p.name .. " exit(" .. tostring(p.exit_code) .. ")")
      ipc.publish("proc.exit", { id = p.id, name = p.name, code = p.exit_code })
      proc_mod.dispose(p)
    else
      p.status = "ready"
    end
  else
    p.status = "ready"
  end
end

local function resume_proc_full(p)
  -- Single resume cycle. The OC sandbox's `coroutine.resume` already bubbles
  -- machine.lua's syscall yields (indirect component calls) through to the
  -- host transparently; our scheduler only ever sees user-mode yields, which
  -- are tables produced by sched.sleep / sched.wait / sched.exit.
  current_proc = p
  p.status = "running"
  local last = p.kv.last_event
  p.kv.last_event = nil
  local ok, req = coroutine.resume(p.coroutine, last)
  current_proc = nil
  if not ok then
    log.error("sched", "process " .. p.name .. "(" .. p.id .. ") crashed: " .. tostring(req))
    p.status = "dead"
    p.exit_code = -1
    ipc.publish("proc.exit", { id = p.id, name = p.name, code = -1, reason = tostring(req) })
    proc_mod.dispose(p)
    return
  end
  if coroutine.status(p.coroutine) == "dead" then
    if p.status ~= "dead" then
      p.status = "dead"
      p.exit_code = p.exit_code or 0
      ipc.publish("proc.exit", { id = p.id, name = p.name, code = p.exit_code })
      proc_mod.dispose(p)
    end
    return
  end
  process_yield(p, req)
end

-- ---- public API ---------------------------------------------------------

function M.init()
  shutdown_requested = false
  ready = {}
  -- Connect signal pump to ipc fan-out.
  signal.bind_ipc(ipc)
end

function M.current() return current_proc end

function M.spawn(fn, opts)
  opts = opts or {}
  opts.parent = opts.parent or current_proc
  local p = proc_mod.create(opts)
  local co = coroutine.create(fn)
  proc_mod.attach_coroutine(p, co)
  p.status = "ready"
  log.debug("sched", "spawned " .. p.name .. " (id=" .. p.id .. ")")
  ipc.publish("proc.start", { id = p.id, name = p.name })
  return p
end

function M.sleep(seconds)
  local p = current_proc
  if not p then error("sched.sleep called outside a process", 2) end
  return coroutine.yield({ kind = "sleep", deadline = computer.uptime() + (seconds or 0) })
end

function M.wait(filter, timeout)
  local p = current_proc
  if not p then error("sched.wait called outside a process", 2) end
  local req = { kind = "wait", filter = filter }
  if timeout then req.deadline = computer.uptime() + timeout end
  return coroutine.yield(req)
end

function M.exit(code)
  local p = current_proc
  if not p then error("sched.exit called outside a process", 2) end
  return coroutine.yield({ kind = "exit", code = code or 0 })
end

function M.shutdown() shutdown_requested = true end

function M.run()
  log.info("sched", "scheduler running")
  while not shutdown_requested do
    -- 1. resume any process that's ready or whose timer fired.
    local procs = proc_mod.list()
    local progressed = false
    for _, p in ipairs(procs) do
      if is_ready(p) then
        if p.status == "sleeping" then
          p.status = "ready"
        end
        resume_proc_full(p)
        progressed = true
      end
    end

    -- 2. drain signals. Use compute_wait so we don't stall a sleeping proc.
    local timeout = compute_wait()
    local ev = table.pack(signal.pull(timeout))
    if ev.n > 0 and ev[1] then
      dispatch_event(table.unpack(ev, 1, ev.n))
    end

    -- 3. if no process is alive, panic loudly so we can debug it.
    if #proc_mod.list() == 0 then
      log.fatal("sched", "no processes left, halting")
      local panic = require("k.panic")
      local entries = log.entries()
      local lines = {}
      for _, e in ipairs(entries) do
        lines[#lines + 1] = string.format("[%8.3f] %s %s: %s", e.time, e.level, e.tag, e.msg)
      end
      panic.halt("scheduler ran out of processes", table.concat(lines, "\n"))
      break
    end
    if not progressed and ev.n == 0 then
      -- Shouldn't loop hot if compute_wait was honest, but just in case:
      computer.pullSignal(0)
    end
  end
  log.info("sched", "scheduler exiting")
end

return M
