-- /sys/svc/uid.lua — UI/desktop service.
--
-- Owns the compositor for the lifetime of the GUI session. Suspends the
-- TTY session (sessiond) on start so both don't draw on the same screen,
-- launches the desktop app, and resumes sessiond on exit. The desktop
-- app receives a session table containing the live compositor.

local sched   = require("k.sched")
local ipc     = require("k.ipc")
local log     = require("k.log")
local ui      = require("lib.ui")
local theme_m = require("lib.ui.theme")
local vfs     = require("k.vfs")

ipc.publish("svc.suspend.sessiond", true)
sched.sleep(0.1)                                   -- give sessiond a tick to release the screen

local function resume_tty()
  ipc.publish("svc.resume.sessiond", true)
end

local theme = theme_m.current()
local compositor, err = ui.compositor.new({ theme = theme })
if not compositor then
  log.error("uid", "compositor: " .. tostring(err))
  resume_tty()
  return 1
end

_G._OCOS_UI_SESSION = { compositor = compositor }

local desktop_main = "/apps/desktop.app/Main.lua"
if vfs.exists(desktop_main) then
  local fn, lerr = load(vfs.read_all(desktop_main), "=" .. desktop_main, "t", _G)
  if fn then
    local ok, ferr = pcall(fn, {}, {}, _G._OCOS_UI_SESSION)
    if not ok then log.error("uid", "desktop run: " .. tostring(ferr)) end
  else
    log.error("uid", "desktop load: " .. tostring(lerr))
  end
end

ipc.subscribe("svc.stop.uid", function() compositor:request_stop() end)

local ok, run_err = pcall(function() compositor:run() end)
if not ok then log.error("uid", "compositor: " .. tostring(run_err)) end

_G._OCOS_UI_SESSION = nil
resume_tty()
return 0
