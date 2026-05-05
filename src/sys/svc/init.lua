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

local function safe_mode_main()
  console.init()
  console.set_fg(0xFFCC66); console.writeln("OCOS safe mode")
  console.set_fg(0xCCCCCC)
  console.writeln("Only the kernel ring logger is running. Type `exit` to reboot.")
  console.writeln("")
  local tty = require("lib.term.tty")
  local streams = { stdin = tty.stdin(), stdout = tty.stdout(), stderr = tty.stderr() }
  local sh, err = exec.exec("/bin/sh.lua", {}, {
    streams   = streams,
    shell_env = { PATH = "/bin", PWD = "/", HOME = "/", USER = "root" },
    caps      = { "*" },
    name      = "sh:safe",
  })
  if not sh then
    streams.stderr:write("safe-mode: cannot launch shell: " .. tostring(err) .. "\n")
    while true do sched.sleep(60) end
  end
  sched.wait_pid(sh.id)
  computer.shutdown(true)
end

function M.main()
  log.info("init", "init service starting")

  if vfs.exists("/etc/boot.selftest") then
    return require("diag.selftest").run()
  end

  local mode = _G._OCOS_BOOT_MODE or "gui"
  log.info("init", "boot mode: " .. mode)

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
  if mode == "console" then
    svcmgr.set_unit_autostart("uid", false)
  end

  local order, err = svcmgr.start_autostart()
  if not order then
    log.error("init", "service ordering failed: " .. tostring(err))
  else
    log.info("init", "started services: " .. table.concat(order, ", "))
  end

  while true do sched.sleep(60) end
end

return M
