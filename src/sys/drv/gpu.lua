-- /sys/drv/gpu.lua — GPU driver.
-- Owns one (gpu, screen) pair and exposes text-cell primitives. The compositor
-- in lib/ui sits on top of these and adds off-screen buffer allocation +
-- dirty-rect tracking; the driver itself stays a thin OC-API wrapper.

local M = {}

local ipc = require("k.ipc")
local log = require("k.log")

local active                                     -- {addr, proxy, screen_addr, w, h, depth}

local function bind_pair(gpu_addr, screen_addr)
  local proxy = component.proxy(gpu_addr)
  -- The EEPROM bios already calls gpu.bind(screen) before /init.lua runs, so
  -- we only re-bind if the active screen has changed (e.g. on hot-plug).
  local current = proxy.getScreen and proxy.getScreen() or screen_addr
  if current ~= screen_addr then
    local ok, err = proxy.bind(screen_addr)
    if not ok then
      log.warn("gpu", "bind failed " .. gpu_addr:sub(1, 8) .. " -> " .. screen_addr:sub(1, 8) .. ": " .. tostring(err))
      return nil
    end
  end
  -- Use whatever resolution the BIOS left active. Bumping to maxResolution
  -- on tier-1 GPUs in some emulators triggers "unsupported resolution".
  local w, h = proxy.getResolution()
  proxy.setBackground(0x000000)
  proxy.setForeground(0xCCCCCC)
  proxy.fill(1, 1, w, h, " ")
  log.info("gpu", "active " .. gpu_addr:sub(1, 8) .. " -> " .. screen_addr:sub(1, 8) .. " (" .. w .. "x" .. h .. ")")
  return { addr = gpu_addr, proxy = proxy, screen_addr = screen_addr, w = w, h = h }
end

local function try_bind()
  if active then return end
  local gpu_addr = component.list("gpu")()
  local screen_addr = component.list("screen")()
  if gpu_addr and screen_addr then
    active = bind_pair(gpu_addr, screen_addr)
    if active then ipc.publish("ui.gpu.bound", { gpu = gpu_addr, screen = screen_addr, w = active.w, h = active.h }) end
  end
end

function M.init()
  ipc.subscribe("oc.signal.component_added", function(p)
    local _, ctype = p[1], p[2]
    if ctype == "gpu" or ctype == "screen" then try_bind() end
  end)
  ipc.subscribe("oc.signal.component_removed", function(p)
    local addr = p[1]
    if active and (addr == active.addr or addr == active.screen_addr) then
      log.warn("gpu", "active component lost; rebinding")
      active = nil
      try_bind()
    end
  end)
  try_bind()
end

function M.active() return active end

function M.set(x, y, s)            return active and active.proxy.set(x, y, s) end
function M.fill(x, y, w, h, ch)    return active and active.proxy.fill(x, y, w, h, ch or " ") end
function M.copy(x, y, w, h, dx, dy) return active and active.proxy.copy(x, y, w, h, dx, dy) end
function M.size()                  return active and active.w, active and active.h end
function M.set_fg(c)               return active and active.proxy.setForeground(c) end
function M.set_bg(c)               return active and active.proxy.setBackground(c) end
function M.get_fg()                return active and active.proxy.getForeground() end
function M.get_bg()                return active and active.proxy.getBackground() end
function M.clear()
  if not active then return end
  active.proxy.fill(1, 1, active.w, active.h, " ")
end

return M
