-- /sys/svc/uid.lua — UI/desktop service.
--
-- Owns the compositor for the lifetime of the GUI session. Asks sessiond
-- to pause its shell child (via svc.suspend.sessiond — sessiond flips the
-- shell's proc.status so it stops consuming key events) and resumes it on
-- exit. The shell process keeps its history, env and command line intact
-- across the GUI session — there's no fresh login when the desktop closes.
--
-- Each step is recorded in /var/log/uid.trace; if the GUI fails to come
-- up, that trace is the place to look.

local sched   = require("k.sched")
local ipc     = require("k.ipc")
local log     = require("k.log")
local ui      = require("lib.ui")
local theme_m = require("lib.ui.theme")
local vfs     = require("k.vfs")
local gpu     = require("drv.gpu")

local function trace(msg)
  pcall(vfs.mkdir, "/var")
  pcall(vfs.mkdir, "/var/log")
  local h = vfs.open("/var/log/uid.trace", "a")
  if not h then return end
  h:write(string.format("[%8.3f] %s\n", computer.uptime(), msg))
  h:close()
end

trace("uid up")

-- Build the compositor BEFORE we ask sessiond to pause; if we can't draw,
-- there's no point disturbing the user's TTY session.
local w, h = gpu.size()
trace("gpu size " .. tostring(w) .. "x" .. tostring(h))
if not w or w <= 0 or not h or h <= 0 then
  log.error("uid", "compositor: gpu has no resolution (" .. tostring(w) .. "x" .. tostring(h) .. ")")
  trace("abort: gpu 0x0")
  return 1
end

local theme_ok, theme = pcall(theme_m.current)
if not theme_ok then
  log.error("uid", "theme: " .. tostring(theme))
  trace("abort: theme load failed")
  return 1
end

local compositor, cerr = ui.compositor.new({ theme = theme })
if not compositor then
  log.error("uid", "compositor.new: " .. tostring(cerr))
  trace("abort: compositor.new -- " .. tostring(cerr))
  return 1
end
trace("compositor ready")

-- Now it's safe to ask the TTY session to step aside.
ipc.publish("svc.suspend.sessiond", true)
sched.sleep(0.05)
trace("tty paused")

local function resume_tty()
  ipc.publish("svc.resume.sessiond", true)
end

-- Paint a holding splash so the user sees the GUI took over even before
-- the desktop app has loaded.
gpu.set_bg(theme.palette and theme.palette.bg or 0x1F1F1F)
gpu.set_fg(theme.palette and theme.palette.muted or 0x888888)
gpu.fill(1, 1, w, h, " ")
gpu.set(2, 2, "OCOS desktop loading…")

_G._OCOS_UI_SESSION = { compositor = compositor }

local desktop_main = "/apps/desktop.app/Main.lua"
if vfs.exists(desktop_main) then
  local fn, lerr = load(vfs.read_all(desktop_main), "=" .. desktop_main, "t", _G)
  if fn then
    local dok, derr = pcall(fn, {}, {}, _G._OCOS_UI_SESSION)
    if not dok then
      log.error("uid", "desktop run: " .. tostring(derr))
      trace("desktop run failed: " .. tostring(derr))
    else
      trace("desktop loaded")
    end
  else
    log.error("uid", "desktop load: " .. tostring(lerr))
    trace("desktop load failed: " .. tostring(lerr))
  end
end

ipc.subscribe("svc.stop.uid", function() compositor:request_stop() end)

local rok, rerr = pcall(function() compositor:run() end)
if not rok then
  log.error("uid", "compositor.run: " .. tostring(rerr))
  trace("compositor.run failed: " .. tostring(rerr))
end

trace("uid exit")
_G._OCOS_UI_SESSION = nil
resume_tty()
return 0
