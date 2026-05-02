-- OCOS /sys/boot.lua
-- Bootstrap layer. Receives the boot filesystem address and a raw read_all helper
-- from /init.lua. Builds a minimal `require` rooted at /sys/, loads kernel modules
-- in order, then yields control to the scheduler, which never returns.

local boot_addr, read_all = ...

_G._OSVERSION = "OCOS 0.1.0-dev"
_G._OCOS = { boot_addr = boot_addr, started_at = computer.uptime() }

-- ---- early-boot trace ----------------------------------------------------
-- Writes a one-line breadcrumb to the first writable filesystem we find. The
-- VFS is not up yet so we go through component.invoke directly. Useful for
-- debugging when the screen is unreadable (e.g. captured terminals).

-- Find and remember the first writable, non-boot filesystem so we don't
-- re-scan on every call. The trace file is rebuilt cumulatively in memory
-- and rewritten with mode "w" each time — ocvm only persists files on close.
local _trace_fs, _trace_buf = nil, ""
do
  for addr in component.list("filesystem") do
    if addr ~= boot_addr then
      local ok, ro = pcall(component.invoke, addr, "isReadOnly")
      if ok and ro == false then _trace_fs = addr; break end
    end
  end
end
local function _trace(msg)
  if not _trace_fs then return end
  _trace_buf = _trace_buf .. string.format("[%8.3f] %s\n", computer.uptime(), msg)
  local oks, h = pcall(component.invoke, _trace_fs, "open", "/boot.trace", "w")
  if oks and h then
    pcall(component.invoke, _trace_fs, "write", h, _trace_buf)
    pcall(component.invoke, _trace_fs, "close", h)
  end
end
_G._BOOT_TRACE = _trace
_trace("boot.lua entered")

-- ---- Minimal require ----------------------------------------------------
-- Resolves dotted names against /sys/?.lua and /sys/?/init.lua, caches modules.
-- This is intentionally tiny; the full stdlib `package` lib is loaded later.

local loaded = {}
local function _require(name)
  if loaded[name] then return loaded[name] end
  local rel = name:gsub("%.", "/")
  local candidates = { "/sys/" .. rel .. ".lua", "/sys/" .. rel .. "/init.lua" }
  local src, src_path
  for _, p in ipairs(candidates) do
    local ok, data = pcall(read_all, p)
    if ok then src, src_path = data, p; break end
  end
  if not src then
    error("require: module not found: " .. name, 2)
  end
  local chunk, err = load(src, "=" .. src_path, "t", _G)
  if not chunk then error("require: cannot load " .. name .. ": " .. tostring(err), 0) end
  loaded[name] = true                  -- mark in-flight to break cycles
  local result = chunk()
  loaded[name] = result == nil and true or result
  return loaded[name]
end
_G.require = _require

-- ---- Kernel boot order --------------------------------------------------
-- Each kernel module returns a table with at least `init(opts)`. We call them
-- in dependency order. After this block, the scheduler is the boss.

local log    = _require("k.log");    log.init({ ring_size = 256 })
local panic  = _require("k.panic");  panic.init()
local signal = _require("k.signal"); signal.init()
local ipc    = _require("k.ipc");    ipc.init()
local cap    = _require("k.cap");    cap.init({ enforce = false })   -- M1: log-only
local vfs    = _require("k.vfs");    vfs.init({ boot_addr = boot_addr })
local proc   = _require("k.proc");   proc.init()
local sched  = _require("k.sched");  sched.init()

log.info("boot", _OSVERSION .. " booting on " .. boot_addr:sub(1, 8))
_trace("kernel modules loaded")

-- ---- Drivers ------------------------------------------------------------
-- Each driver registers on component_added/removed via the IPC bus. They claim
-- whatever components are already attached at boot time (via the scheduler's
-- replay below), so they don't need to poll.

_require("drv.gpu").init()
_require("drv.screen").init()
_require("drv.kbd").init()
_require("drv.fs").init()

-- ---- Replay component_added for everything attached at boot -------------
-- Real boot fires component_added later, but our drivers want to bind at once.

for addr, ctype in component.list() do
  ipc.publish("oc.signal.component_added", table.pack(addr, ctype))
end

-- ---- First user process -------------------------------------------------
-- /sys/svc/init.lua is the system manager. In M1 it's just "spawn the shell".

local init_proc = _require("svc.init")
sched.spawn(init_proc.main, { name = "init", caps = { "*" } })

-- ---- Hand control to the scheduler --------------------------------------
log.info("boot", "kernel initialised, entering scheduler")
_trace("entering scheduler")
sched.run()                                      -- does not return
_trace("SCHEDULER RETURNED — should never happen")
