-- /sys/svc/uid.lua — UI/desktop service.
--
-- Owns the compositor for the lifetime of the GUI session. Launches the
-- desktop app first, then any other autostarted GUI apps. When the user
-- chooses to log out, the compositor is torn down and uid exits, allowing
-- the supervisor to fall back to sessiond if no other GUI service starts.

local sched   = require("k.sched")
local ipc     = require("k.ipc")
local log     = require("k.log")
local ui      = require("lib.ui")
local exec    = require("k.exec")
local theme_m = require("lib.ui.theme")
local stream  = require("std.stream")
local vfs     = require("k.vfs")

local STOP = "__svc_stop_uid"
ipc.subscribe("svc.stop.uid", function() computer.pushSignal(STOP) end)

local theme = theme_m.current()

local compositor, err = ui.compositor.new({ theme = theme })
if not compositor then
  log.error("uid", "compositor: " .. tostring(err))
  return 1
end

-- Make the live session available to the desktop app and any other GUI
-- consumers via a well-known global. We do not pass it on the command line
-- because spawned apps live in their own processes; the session table is
-- read inside their loaded chunks via _G.
_G._OCOS_UI_SESSION = { compositor = compositor }

-- Launch the desktop app inside the same coroutine; its Main.lua simply
-- adds widgets to the compositor and returns.
local desktop_main = "/apps/desktop.app/Main.lua"
if vfs.exists(desktop_main) then
  local fn, lerr = load(vfs.read_all(desktop_main), "=" .. desktop_main, "t", _G)
  if fn then pcall(fn, {}, {}, _G._OCOS_UI_SESSION)
  else log.error("uid", "desktop load: " .. tostring(lerr)) end
end

-- Subscribe to stop request via a flag we'll check between event ticks.
local stop_req = false
ipc.subscribe("svc.stop.uid", function() stop_req = true; compositor:request_stop() end)

compositor:run()

_G._OCOS_UI_SESSION = nil
return 0
