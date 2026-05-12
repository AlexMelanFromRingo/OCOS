-- /sys/drv/gpu.lua — GPU driver.
-- Owns one (gpu, screen) pair and exposes text-cell primitives. The compositor
-- in lib/ui sits on top of these and adds off-screen buffer allocation +
-- dirty-rect tracking; the driver itself stays a thin OC-API wrapper.

local M = {}

local ipc = require("k.ipc")
local log = require("k.log")

local active                                     -- {addr, proxy, screen_addr, w, h, depth}

local function try_alloc_backbuffer(proxy, w, h)
  -- T3 GPU exposes allocateBuffer / setActiveBuffer / bitblt; T1/T2
  -- and pre-1.7.5 OC don't. We allocate one off-screen buffer matching
  -- the screen, render whole frames into it, and bitblt to buffer 0
  -- (the screen) in one atomic call. That eliminates the partial-row
  -- tearing players see when many gpu.set calls happen in sequence.
  if not (proxy.allocateBuffer and proxy.setActiveBuffer and proxy.bitblt) then
    return nil
  end
  local ok, idx = pcall(proxy.allocateBuffer, w, h)
  if not ok or type(idx) ~= "number" or idx <= 0 then return nil end
  -- Prime the buffer to the same defaults the screen starts with.
  local prev = proxy.getActiveBuffer and proxy.getActiveBuffer() or 0
  pcall(proxy.setActiveBuffer, idx)
  pcall(proxy.setBackground, 0x000000)
  pcall(proxy.setForeground, 0xCCCCCC)
  pcall(proxy.fill, 1, 1, w, h, " ")
  pcall(proxy.setActiveBuffer, prev)
  return idx
end

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
  local back = try_alloc_backbuffer(proxy, w, h)
  if back then
    log.info("gpu", "T3 backbuffer allocated (idx=" .. back .. ")")
  end
  log.info("gpu", "active " .. gpu_addr:sub(1, 8) .. " -> " .. screen_addr:sub(1, 8) .. " (" .. w .. "x" .. h .. ")")
  return {
    addr = gpu_addr, proxy = proxy, screen_addr = screen_addr,
    w = w, h = h, back = back, in_frame = false,
  }
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

-- Frame protocol for the compositor: begin_frame() redirects writes
-- into the off-screen back buffer (no flicker visible to the player);
-- end_frame() flips the active buffer back and bitblts the whole back
-- buffer to the screen in one operation. On GPUs without buffer
-- support both calls are no-ops and rendering happens directly.
function M.begin_frame()
  if not active or not active.back or active.in_frame then return false end
  local prev = active.proxy.getActiveBuffer and active.proxy.getActiveBuffer() or 0
  local ok = pcall(active.proxy.setActiveBuffer, active.back)
  if not ok then return false end
  active.prev_buf = prev
  active.in_frame = true
  return true
end

function M.end_frame()
  if not active or not active.in_frame then return false end
  active.in_frame = false
  local prev = active.prev_buf or 0
  pcall(active.proxy.setActiveBuffer, prev)
  -- bitblt(dst, col, row, w, h, src, fromCol, fromRow). dst defaults
  -- to active when omitted, but passing it explicitly is more robust.
  pcall(active.proxy.bitblt, prev, 1, 1, active.w, active.h,
        active.back, 1, 1)
  return true
end

function M.has_backbuffer() return active and active.back ~= nil or false end

-- Drop the current back buffer (resize, theme swap, or shutdown) and
-- try to allocate a fresh one matching the active resolution. Called
-- from compositor on resize signals.
function M.reset_backbuffer()
  if not active then return end
  if active.back and active.proxy.freeBuffer then
    pcall(active.proxy.freeBuffer, active.back)
  end
  active.back = nil
  local w, h = active.proxy.getResolution()
  active.w, active.h = w, h
  active.back = try_alloc_backbuffer(active.proxy, w, h)
end

-- Refresh cached resolution after an explicit setResolution call.
function M.refresh_size()
  if not active then return nil end
  local w, h = active.proxy.getResolution()
  active.w, active.h = w, h
  return w, h
end

return M
