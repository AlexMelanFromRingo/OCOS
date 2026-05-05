-- /sys/svc/uid.lua — UI/desktop service.
--
-- Boot order:
--   1. Build a compositor.
--   2. Suspend sessiond (release the screen) and paint a holding splash.
--   3. If /etc/passwd has accounts, run the login picker scene first;
--      compositor:run() returns when the picker calls request_stop().
--   4. Load /apps/desktop.app/Main.lua with the resolved session env;
--      compositor:run() again handles desktop events until uid is asked
--      to stop (Power → Log out, or `svc stop uid`).

local sched   = require("k.sched")
local ipc     = require("k.ipc")
local log     = require("k.log")
local ui      = require("lib.ui")
local theme_m = require("lib.ui.theme")
local vfs     = require("k.vfs")
local gpu     = require("drv.gpu")
local users   = require("lib.auth.users")

local trace = require("lib.diag.trace").for_name("uid")
trace("uid up")

local w, h = gpu.size()
trace("gpu size " .. tostring(w) .. "x" .. tostring(h))
if not w or w <= 0 or not h or h <= 0 then
  log.error("uid", "gpu has no resolution"); return 1
end

local theme_ok, theme = pcall(theme_m.current)
if not theme_ok then log.error("uid", "theme: " .. tostring(theme)); return 1 end

local compositor, cerr = ui.compositor.new({ theme = theme })
if not compositor then
  log.error("uid", "compositor.new: " .. tostring(cerr)); return 1
end
trace("compositor ready")

ipc.publish("svc.suspend.sessiond", true)
sched.sleep(0.05)
trace("tty paused")

local function resume_tty() ipc.publish("svc.resume.sessiond", true) end

gpu.set_bg(theme.palette and theme.palette.bg or 0x1F1F1F)
gpu.set_fg(theme.palette and theme.palette.muted or 0x888888)
gpu.fill(1, 1, w, h, " ")
gpu.set(2, 2, "OCOS desktop loading…")

local session = { compositor = compositor }
_G._OCOS_UI_SESSION = session

local function run_app(path, env)
  if not vfs.exists(path) then return end
  local fn, lerr = load(vfs.read_all(path), "=" .. path, "t", _G)
  if not fn then log.error("uid", path .. ": " .. tostring(lerr)); return end
  local ok, e = pcall(fn, {}, env or {}, session)
  if not ok then log.error("uid", path .. " run: " .. tostring(e)) end
end

-- ---- login picker (when /etc/passwd is non-empty) -------------------

local session_env = { USER = "root", HOME = "/home", caps = {"*"} }

if not users.empty() then
  trace("login picker required")
  local got
  local sub = ipc.subscribe("ses.login.ok", function(p)
    got = p
    compositor:request_stop()
  end)
  run_app("/apps/login.app/Main.lua", {})
  -- compositor:run loops until the picker stops it via request_stop().
  local ok = pcall(function() compositor:run() end)
  ipc.unsubscribe(sub)
  if not ok or not got then
    trace("login aborted")
    resume_tty(); return 1
  end
  session_env.USER = got.user
  session_env.HOME = got.rec.home or ("/home/" .. got.user)
  session_env.caps = got.rec.caps or {"*"}
  trace("login ok: " .. got.user)
  -- Clear picker scene + reset stop flag for the desktop run.
  compositor.root.children = {}
  compositor.stop = false
  compositor.dirty = true
  compositor:invalidate()
end

-- ---- desktop --------------------------------------------------------

run_app("/apps/desktop.app/Main.lua", session_env)
trace("desktop loaded as " .. session_env.USER)

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
