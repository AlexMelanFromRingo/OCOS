-- /sys/svc/uid.lua — UI/desktop service.
--
-- The whole flow is wrapped in xpcall so a syntax error or runtime
-- crash in any widget / app reaches /uid.panic and the gpu instead of
-- silently disappearing. /uid.panic is written with raw component
-- access so it survives the cap stack failing.

local sched   = require("k.sched")
local ipc     = require("k.ipc")
local log     = require("k.log")
local diag    = require("lib.diag.trace")
local trace   = diag.for_name("uid")
trace("uid up")

local function panic_to_screen(msg)
  -- Best-effort crash dump straight to the gpu so the user sees what
  -- happened even if the compositor never came up.
  local addr = component.list("gpu")()
  local screen = component.list("screen")()
  if not addr then return end
  pcall(component.invoke, addr, "bind", screen)
  pcall(component.invoke, addr, "setBackground", 0x1A0000)
  pcall(component.invoke, addr, "setForeground", 0xFFCC66)
  pcall(component.invoke, addr, "fill", 1, 1, 160, 50, " ")
  pcall(component.invoke, addr, "set", 2, 2, "OCOS GUI panic")
  pcall(component.invoke, addr, "setForeground", 0xFFFFFF)
  -- Wrap message into 60-char rows starting at row 4.
  local s = tostring(msg or "?")
  local row = 4
  while #s > 0 and row < 50 do
    pcall(component.invoke, addr, "set", 2, row, s:sub(1, 158))
    s = s:sub(159)
    row = row + 1
  end
  pcall(component.invoke, addr, "setForeground", 0x888888)
  pcall(component.invoke, addr, "set", 2, math.min(row + 1, 49),
    "Reboot the machine. Trace: /uid.panic on the boot disk.")
end

local function run()
  local ui      = require("lib.ui")
  local theme_m = require("lib.ui.theme")
  local vfs     = require("k.vfs")
  local gpu     = require("drv.gpu")
  local users   = require("lib.auth.users")

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

  gpu.set_bg(theme.palette and theme.palette.bg or 0x1F1F1F)
  gpu.set_fg(theme.palette and theme.palette.muted or 0x888888)
  gpu.fill(1, 1, w, h, " ")
  gpu.set(2, 2, "OCOS desktop loading…")

  local session = { compositor = compositor }
  _G._OCOS_UI_SESSION = session
  -- Apps register teardown callbacks here so the next session starts
  -- with a clean slate (no stale ipc subscriptions firing into a dead
  -- widget tree, no leaked desktop-tick coroutine doubling each frame).
  session.teardown = {}
  function session.on_teardown(fn) session.teardown[#session.teardown + 1] = fn end

  local function run_app(path, env)
    if not vfs.exists(path) then trace("missing app: " .. path); return end
    local fn, lerr = load(vfs.read_all(path), "=" .. path, "t", _G)
    if not fn then
      log.error("uid", path .. " load: " .. tostring(lerr))
      trace(path .. " load failed: " .. tostring(lerr))
      return
    end
    local ok, e = pcall(fn, {}, env or {}, session)
    if not ok then
      log.error("uid", path .. " run: " .. tostring(e))
      trace(path .. " run failed: " .. tostring(e))
    end
  end

  -- "soft" stop = compositor returned because the user requested
  -- Switch user / Log out — the outer loop should re-show the login
  -- picker. "hard" stop = svc.stop.uid (services subsystem killing
  -- us) — exit the whole service.
  local mode = "boot"                              -- "boot" | "switch" | "hard"
  ipc.subscribe("svc.stop.uid",     function() mode = "hard";   compositor:request_stop() end)
  ipc.subscribe("ses.switch_user",  function() mode = "switch"; compositor:request_stop() end)
  ipc.subscribe("ses.logout",       function() mode = "switch"; compositor:request_stop() end)

  while mode ~= "hard" do
    local session_env = { USER = "root", HOME = "/home", caps = {"*"} }

    if not users.empty() then
      trace("login picker required")
      local got
      local sub = ipc.subscribe("ses.login.ok", function(p)
        got = p; compositor:request_stop()
      end)
      mode = "boot"                                -- entering the picker; reset
      compositor.root.children = {}
      compositor.stop = false
      compositor.buffer:invalidate()               -- wipe artefacts from previous session
      run_app("/apps/login.app/Main.lua", {})
      pcall(function() compositor:run() end)
      ipc.unsubscribe(sub)
      if mode == "hard" then trace("hard stop during login"); return 0 end
      if not got then trace("login aborted"); return 1 end
      session_env.USER = got.user
      session_env.HOME = got.rec.home or ("/home/" .. got.user)
      session_env.caps = got.rec.caps or {"*"}
      trace("login ok: " .. got.user)
    end

    -- Reset the workspace before running the desktop. After a
    -- previous session the compositor still holds the old desktop
    -- tree, the WM list and any subscriptions that closed over them.
    compositor.root.children = {}
    compositor.stop          = false
    compositor.wm            = nil
    compositor.buffer:invalidate()

    run_app("/apps/desktop.app/Main.lua", session_env)
    trace("desktop loaded as " .. session_env.USER)
    mode = "boot"                                  -- ready for next request
    _G._OCOS_UI_USER = session_env.USER

    local rok, rerr = xpcall(function() compositor:run() end, function(e)
      return tostring(e) .. "\n" .. debug.traceback("", 2)
    end)
    if not rok then
      log.error("uid", "compositor.run: " .. tostring(rerr))
      trace("compositor.run failed: " .. tostring(rerr))
      error(rerr, 0)                               -- bubble to outer xpcall
    end

    -- Run app teardown callbacks (unsubscribe ipc handles, kill
    -- background coroutines registered via session.on_teardown).
    for i = #session.teardown, 1, -1 do
      pcall(session.teardown[i])
    end
    session.teardown = {}
    if mode == "hard" then break end
    -- mode == "switch": loop back to the login picker.
    trace("session ended, re-prompting (mode=" .. mode .. ")")
  end

  return 0
end

local ok, err = xpcall(run, function(e)
  return tostring(e) .. "\n" .. debug.traceback("", 2)
end)
if not ok then
  trace("PANIC: " .. tostring(err))
  diag.panic("uid", tostring(err))
  panic_to_screen(err)
  -- Hold the screen for a few seconds before resume_tty so the user
  -- can read the message instead of it being wiped by sessiond's
  -- console.redraw immediately.
  sched.sleep(8)
end

trace("uid exit")
_G._OCOS_UI_SESSION = nil
ipc.publish("svc.resume.sessiond", true)
return ok and 0 or 1
