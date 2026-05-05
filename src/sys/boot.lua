-- /sys/boot.lua — bootstrap layer.
--
-- /init.lua hands us the boot filesystem address and a raw read_all helper
-- (the VFS isn't loaded yet). We build a minimal `require` rooted at /sys/,
-- bring up the kernel modules in dependency order, fire each driver's
-- registration logic, replay component_added so they discover existing
-- hardware, spawn the init service, and hand control to the scheduler,
-- which never returns.

local boot_addr, read_all = ...

_G._OSVERSION = "OCOS 0.2.0"
_G._OCOS = { boot_addr = boot_addr, started_at = computer.uptime() }

-- ---- boot mode menu -----------------------------------------------------
--
-- Runs before any kernel module is loaded, talking to the GPU via raw
-- component.invoke and to the keyboard via computer.pullSignal. If the
-- BIOS already pinned a mode (via eeprom.getData() {mode=...}) we skip
-- the menu and respect the pre-selected choice.

-- Skip the menu entirely when the selftest marker is present — it eats
-- 3 s of the test-boot.sh budget for no reason. We also skip when the
-- BIOS already chose a mode via eeprom.getData() {mode=...}.
local function _selftest_marker()
  local boot_proxy = component.proxy(boot_addr)
  return boot_proxy and boot_proxy.exists and boot_proxy.exists("/etc/boot.selftest")
end

if not _G._OCOS_BOOT_MODE and not _selftest_marker() then
  local gpu_addr = component.list("gpu")()
  if gpu_addr then
    local sw, sh = component.invoke(gpu_addr, "getResolution")
    sw, sh = sw or 80, sh or 25
    component.invoke(gpu_addr, "setBackground", 0x000A14)
    component.invoke(gpu_addr, "fill", 1, 1, sw, sh, " ")
    component.invoke(gpu_addr, "setForeground", 0xCCCCFF)
    component.invoke(gpu_addr, "set", 2, 2, _OSVERSION)
    component.invoke(gpu_addr, "setForeground", 0xFFFFFF)
    component.invoke(gpu_addr, "set", 2, 4, "Choose boot mode:")
    component.invoke(gpu_addr, "setForeground", 0xCCCCCC)
    component.invoke(gpu_addr, "set", 4, 5, "1. Desktop (GUI, default)")
    component.invoke(gpu_addr, "set", 4, 6, "2. Console (TTY only)")
    component.invoke(gpu_addr, "set", 4, 7, "3. Safe mode")
    component.invoke(gpu_addr, "setForeground", 0x888888)
    component.invoke(gpu_addr, "set", 2, 9, "press 1/2/3 within 3s, Enter for default")

    local deadline = computer.uptime() + 3
    local mode
    while computer.uptime() < deadline do
      local rem = deadline - computer.uptime()
      local ev, _, char, code = computer.pullSignal(rem > 0.1 and 0.1 or rem)
      if ev == "key_down" then
        if code == 28 or code == 156 or char == 49 then mode = "gui"; break end
        if char == 50 then mode = "console"; break end
        if char == 51 then mode = "safe";    break end
      end
    end
    _G._OCOS_BOOT_MODE = mode or "gui"
    component.invoke(gpu_addr, "setBackground", 0x000000)
    component.invoke(gpu_addr, "fill", 1, 1, sw, sh, " ")
  else
    _G._OCOS_BOOT_MODE = "gui"
  end
end
if not _G._OCOS_BOOT_MODE then _G._OCOS_BOOT_MODE = "gui" end
if _G._OCOS_BOOT_MODE == "safe" then _G._OCOS_SAFE = true end

-- ---- Minimal require rooted at /sys/ ------------------------------------

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
  if not src then error("require: module not found: " .. name, 2) end
  local chunk, err = load(src, "=" .. src_path, "t", _G)
  if not chunk then error("require: cannot load " .. name .. ": " .. tostring(err), 0) end
  loaded[name] = true
  local result = chunk()
  loaded[name] = result == nil and true or result
  return loaded[name]
end
_G.require = _require

-- ---- Kernel boot order --------------------------------------------------

local log    = _require("k.log");    log.init({ ring_size = 256 })
local panic  = _require("k.panic");  panic.init()
local signal = _require("k.signal"); signal.init()
local ipc    = _require("k.ipc");    ipc.init()
local cap    = _require("k.cap");    cap.init({ enforce = false })
-- /etc/security.cfg may flip enforcement on after the kernel and VFS are
-- up. We read it here, after vfs.init, but the file lives on the boot fs
-- so we have to defer this read to the post-vfs section below.
local vfs    = _require("k.vfs");    vfs.init({ boot_addr = boot_addr })
local proc   = _require("k.proc");   proc.init()
local sched  = _require("k.sched");  sched.init()

log.info("boot", _OSVERSION .. " booting on " .. boot_addr:sub(1, 8))

-- Apply security policy now that the VFS is mounted.
do
  local sec_path = "/etc/security.cfg"
  if vfs.exists(sec_path) then
    local src = vfs.read_all(sec_path)
    local fn, err = load(src or "", "=" .. sec_path, "t", {})
    if fn then
      local ok, t = pcall(fn)
      if ok and type(t) == "table" then
        cap.set_enforce(t.enforce == true)
        log.info("boot", "security: enforce=" .. tostring(t.enforce == true))
      else
        log.warn("boot", "security.cfg eval: " .. tostring(t))
      end
    else
      log.warn("boot", "security.cfg syntax: " .. tostring(err))
    end
  end
end

-- ---- Drivers ------------------------------------------------------------

_require("drv.gpu").init()
_require("drv.screen").init()
_require("drv.kbd").init()
_require("drv.fs").init()
_require("drv.modem").init()
_require("drv.internet").init()

-- ---- Replay component_added so drivers discover already-attached hw -----

for addr, ctype in component.list() do
  ipc.publish("oc.signal.component_added", table.pack(addr, ctype))
end

-- ---- First user process -------------------------------------------------

local init_svc = _require("svc.init")
sched.spawn(init_svc.main, { name = "init", caps = { "*" } })

-- ---- Hand control to the scheduler --------------------------------------

log.info("boot", "kernel initialised, entering scheduler")
sched.run()                                      -- does not return
