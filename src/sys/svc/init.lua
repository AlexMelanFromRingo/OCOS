-- /sys/svc/init.lua — first user process. Brings up the service manager
-- and lets it own the rest of userland. When /etc/boot.selftest is
-- present we delegate to /sys/diag/selftest.lua instead — keeping the
-- 500-line test battery out of the always-loaded path is what lets
-- OCOS fit on a 1 MiB OC tier-1 machine.

local M = {}

local sched   = require("k.sched")
local log     = require("k.log")
local vfs     = require("k.vfs")
local exec    = require("k.exec")
local console = require("lib.term.console")
local svcmgr  = require("lib.svc.manager")

local trace = require("lib.diag.trace").for_name("init")

local function safe_mode_main()
  trace("safe mode entered")
  console.init()
  console.set_fg(0xFFCC66); console.writeln("OCOS safe mode")
  console.set_fg(0xCCCCCC)
  console.writeln("Only the kernel ring logger is running. Type `exit` to reboot.")
  console.writeln("")
  local tty = require("lib.term.tty")
  local streams = { stdin = tty.stdin(), stdout = tty.stdout(), stderr = tty.stderr() }
  trace("safe: spawning /bin/sh.lua")
  local sh, err = exec.exec("/bin/sh.lua", {}, {
    streams   = streams,
    shell_env = { PATH = "/bin", PWD = "/", HOME = "/", USER = "root" },
    caps      = { "*" },
    name      = "sh:safe",
  })
  if not sh then
    trace("safe: exec FAILED: " .. tostring(err))
    streams.stderr:write("safe-mode: cannot launch shell: " .. tostring(err) .. "\n")
    console.writeln("safe-mode: " .. tostring(err))
    while true do sched.sleep(60) end
  end
  trace("safe: shell pid=" .. sh.id .. " spawned; entering wait_pid")
  sched.wait_pid(sh.id)
  trace("safe: shell exited; rebooting")
  computer.shutdown(true)
end

function M.main()
  log.info("init", "init service starting")
  trace("init.main; _OSVERSION=" .. tostring(_OSVERSION))

  if vfs.exists("/etc/boot.selftest") then
    return require("diag.selftest").run()
  end

  local mode = _G._OCOS_BOOT_MODE or "gui"
  log.info("init", "boot mode: " .. mode)
  trace("boot mode: " .. mode)

  if mode == "safe" then
    svcmgr.bind_supervisor()
    svcmgr.load_units("/etc/services")
    svcmgr.set_unit_autostart("sessiond", false)
    svcmgr.set_unit_autostart("uid", false)
    svcmgr.start_autostart()
    return safe_mode_main()
  end

  svcmgr.bind_supervisor()
  svcmgr.load_units("/etc/services")

  -- In GUI mode uid owns the screen; sessiond's banner paint races with
  -- uid's splash and the result is unreadable. We disable sessiond's
  -- autostart and bring it up only as a fallback when uid exits (e.g.,
  -- the user logs out from the desktop).
  if mode == "gui" then
    svcmgr.set_unit_autostart("sessiond", false)
  elseif mode == "console" then
    svcmgr.set_unit_autostart("uid", false)
  end

  local order, err = svcmgr.start_autostart()
  if not order then
    log.error("init", "service ordering failed: " .. tostring(err))
    trace("autostart failed: " .. tostring(err))
  else
    log.info("init", "started services: " .. table.concat(order, ", "))
    trace("started: " .. table.concat(order, ", "))
  end

  if mode == "gui" then
    require("k.ipc").subscribe("svc.evt", function(evt)
      if evt and evt.id == "uid" and (evt.state == "finished" or evt.state == "failed") then
        log.info("init", "uid stopped (" .. tostring(evt.state) .. "); starting sessiond")
        pcall(svcmgr.start, "sessiond")
      end
    end)
  end

  while true do sched.sleep(60) end
end

return M
