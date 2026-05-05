-- /sys/lib/svc/manager.lua — service supervisor.
--
-- A service is a Lua program declared by a unit file in /etc/services. The
-- manager reads units, starts autostart services in dependency order, and
-- supervises them by subscribing to the proc.exit channel.
--
-- Unit format (Lua table returned from /etc/services/<id>.cfg):
--   {
--     id          = "logd",
--     description = "kernel log persister",
--     exec        = "/sys/svc/logd.lua",         -- script to run
--     args        = {},                          -- argv to the script
--     after       = { "other_id", ... },         -- deps (must be running)
--     caps        = { "syscall:write:/var/log/*", ... },
--     restart     = "always" | "on_failure" | "one_shot",
--     autostart   = true | false,
--     env         = { K = "V", ... },            -- shell-style env
--   }
--
-- State machine: loaded -> starting -> running -> stopping -> finished/failed.

local M = {}

local sched   = require("k.sched")
local exec    = require("k.exec")
local vfs     = require("k.vfs")
local ipc     = require("k.ipc")
local log     = require("k.log")
local stream  = require("std.stream")

local services           -- { id -> service_record }
local proc_exit_handle
local pid_to_id          -- { pid -> service_id }

local DEFAULT_RESTART = "on_failure"

-- ---- helpers ------------------------------------------------------------

local function load_unit(path)
  local src, err = vfs.read_all(path)
  if not src then return nil, err end
  local fn, lerr = load(src, "=" .. path, "t", {})
  if not fn then return nil, lerr end
  local ok, t = pcall(fn)
  if not ok then return nil, tostring(t) end
  if type(t) ~= "table" or not t.id or not t.exec then
    return nil, "unit missing id or exec"
  end
  t.restart   = t.restart   or DEFAULT_RESTART
  t.after     = t.after     or {}
  t.conflicts = t.conflicts or {}
  t.caps      = t.caps      or {}
  t.args      = t.args      or {}
  t.env       = t.env       or {}
  t.autostart = t.autostart ~= false                -- default true
  return t
end

function M.load_units(dir)
  services = services or {}
  pid_to_id = pid_to_id or {}
  if not vfs.isdir(dir) then return 0 end
  local entries = vfs.list(dir) or {}
  local count = 0
  for _, name in ipairs(entries) do
    if name:sub(-4) == ".cfg" then
      local unit, err = load_unit(dir .. "/" .. name)
      if unit then
        services[unit.id] = services[unit.id] or { unit = unit, state = "loaded", restart_count = 0 }
        services[unit.id].unit = unit
        count = count + 1
      else
        log.warn("svc", "unit " .. name .. ": " .. tostring(err))
      end
    end
  end
  return count
end

-- Exposed for standalone unit testing (tools/test-svc-topo.lua) — not
-- part of the public service-manager API.
local function topo_sort(ids)
  -- Kahn's algorithm. `after` declares a strict happens-before edge.
  -- Only edges *between members of `ids`* are walked; if a unit depends
  -- on a disabled (non-autostart) service we silently drop the edge —
  -- the dependent gets started without waiting for the missing peer.
  local in_deg, edges_to = {}, {}
  for _, id in ipairs(ids) do in_deg[id] = 0; edges_to[id] = {} end
  for _, id in ipairs(ids) do
    for _, dep in ipairs(services[id].unit.after) do
      if edges_to[dep] then
        edges_to[dep][#edges_to[dep] + 1] = id
        in_deg[id] = in_deg[id] + 1
      end
    end
  end
  local order, queue = {}, {}
  for _, id in ipairs(ids) do if in_deg[id] == 0 then queue[#queue + 1] = id end end
  while #queue > 0 do
    local id = table.remove(queue, 1)
    order[#order + 1] = id
    for _, succ in ipairs(edges_to[id]) do
      in_deg[succ] = in_deg[succ] - 1
      if in_deg[succ] == 0 then queue[#queue + 1] = succ end
    end
  end
  if #order ~= #ids then
    return nil, "service dependency cycle detected"
  end
  return order
end

local function spawn_service(id)
  local svc = services[id]
  if not svc then return nil, "no such service: " .. id end
  if svc.state == "running" or svc.state == "starting" then return svc end
  svc.state = "starting"
  local p, err = exec.exec(svc.unit.exec, svc.unit.args, {
    streams   = { stdin = stream.null(), stdout = stream.null(), stderr = stream.null() },
    shell_env = svc.unit.env,
    cmdline   = "[" .. id .. "]",
    name      = "svc:" .. id,
    caps      = svc.unit.caps,
  })
  if not p then
    svc.state = "failed"
    svc.last_error = err
    log.error("svc", "start " .. id .. ": " .. tostring(err))
    ipc.publish("svc.evt", { id = id, state = "failed", reason = err })
    return nil, err
  end
  svc.state = "running"
  svc.pid = p.id
  svc.started_at = computer.uptime()
  pid_to_id[p.id] = id
  log.info("svc", "started " .. id .. " (pid=" .. p.id .. ")")
  ipc.publish("svc.evt", { id = id, state = "running", pid = p.id })
  return svc
end

function M.start(id)
  local svc = services[id]
  if not svc then return nil, "no such service: " .. id end
  for _, dep in ipairs(svc.unit.after) do
    if services[dep] and services[dep].state ~= "running" then
      local ok, err = M.start(dep)
      if not ok then return nil, "dep " .. dep .. " failed: " .. tostring(err) end
    end
  end
  -- Resolve conflicts: any declared peer that's currently running gets a
  -- cooperative stop request first. The ipc-based suspend protocol that
  -- sessiond/uid use is finer-grained, but for any other pair this is the
  -- safety net the manager owns.
  for _, peer in ipairs(svc.unit.conflicts) do
    local other = services[peer]
    if other and other.state == "running" then
      local ok, err = M.stop(peer)
      if not ok then return nil, "conflict with " .. peer .. ": " .. tostring(err) end
    end
  end
  return spawn_service(id)
end

function M.stop(id)
  local svc = services[id]
  if not svc or not svc.pid then return nil, "service not running" end
  -- Cooperative stop: publish a stop request on a per-service channel and
  -- wait for the proc to exit. Services are expected to subscribe and exit
  -- voluntarily; the supervisor doesn't have a kill primitive (OC has no
  -- preemption), so a stuck service must be addressed via shutdown/reboot.
  svc.state = "stopping"
  ipc.publish("svc.stop." .. id, true)
  local res = sched.wait_pid(svc.pid, 5)
  if not res then
    svc.state = "running"
    return nil, "service did not exit within 5s"
  end
  return true
end

function M.list()
  local out = {}
  for id, svc in pairs(services or {}) do
    out[#out + 1] = {
      id           = id,
      description  = svc.unit.description,
      state        = svc.state,
      pid          = svc.pid,
      restart_count = svc.restart_count,
      started_at   = svc.started_at,
      last_error   = svc.last_error,
    }
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function M.status(id)
  local svc = services and services[id]
  if not svc then return nil end
  return {
    id            = id,
    description   = svc.unit.description,
    state         = svc.state,
    pid           = svc.pid,
    restart_count = svc.restart_count,
    started_at    = svc.started_at,
    last_error    = svc.last_error,
    unit          = svc.unit,
  }
end

local function on_proc_exit(payload)
  local id = pid_to_id[payload.id]
  if not id then return end
  pid_to_id[payload.id] = nil
  local svc = services[id]; if not svc then return end
  svc.pid = nil
  log.info("svc", id .. " exited code=" .. tostring(payload.code))
  if svc.state == "stopping" then
    svc.state = "finished"
    ipc.publish("svc.evt", { id = id, state = "finished", code = payload.code })
    return
  end
  local policy = svc.unit.restart
  local should_restart =
    policy == "always" or
    (policy == "on_failure" and (payload.code or 0) ~= 0)
  if should_restart and svc.restart_count < 10 then
    svc.restart_count = svc.restart_count + 1
    local delay = math.min(8, 1 * 2 ^ math.min(svc.restart_count - 1, 3))
    log.warn("svc", id .. " will restart in " .. delay .. "s (count=" ..
      svc.restart_count .. ")")
    sched.spawn(function()
      sched.sleep(delay)
      spawn_service(id)
    end, { name = "svc-restart:" .. id, caps = { "*" } })
  else
    svc.state = (payload.code or 0) == 0 and "finished" or "failed"
    svc.last_error = payload.reason
    ipc.publish("svc.evt", { id = id, state = svc.state, code = payload.code })
  end
end

M._topo_sort = topo_sort                          -- exposed for tests only
M._inject_services = function(t) services = t end -- ditto

function M.set_unit_autostart(id, value)
  if not services or not services[id] then return nil, "no such service: " .. id end
  services[id].unit.autostart = value and true or false
  return true
end

function M.start_autostart()
  -- Starts every loaded unit whose autostart flag is true. Useful when
  -- callers want to load_units once, mutate flags (e.g., the boot mode
  -- selector disabling uid), then start; calling start_all_autostart
  -- would clobber those mutations by re-reading the unit files.
  local ids = {}
  for id, svc in pairs(services or {}) do
    if svc.unit.autostart then ids[#ids + 1] = id end
  end
  local order, err = topo_sort(ids)
  if not order then return nil, err end
  for _, id in ipairs(order) do
    local ok, e = spawn_service(id)
    if not ok then log.error("svc", "autostart " .. id .. " failed: " .. tostring(e)) end
  end
  return order
end

function M.start_all_autostart(unit_dir)
  M.load_units(unit_dir)
  return M.start_autostart()
end

function M.bind_supervisor()
  if proc_exit_handle then return end
  proc_exit_handle = ipc.subscribe("proc.exit", on_proc_exit)
end

return M
