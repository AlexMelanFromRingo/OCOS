-- /sys/svc/init.lua — first user process. Brings up the service manager
-- and lets it own the rest of userland. When /etc/boot.selftest is
-- present we delegate to /sys/diag/selftest.lua instead — keeping the
-- 500-line test battery out of the always-loaded path is what lets
-- OCOS fit on a 1 MiB OC tier-1 machine.

local M = {}

local sched   = require("k.sched")
local log     = require("k.log")
local vfs     = require("k.vfs")
local svcmgr  = require("lib.svc.manager")

local trace = require("lib.diag.trace").for_name("init")

function M.main()
  log.info("init", "init service starting")
  trace("init.main; _OSVERSION=" .. tostring(_OSVERSION))

  if vfs.exists("/etc/boot.selftest") then
    return require("diag.selftest").run()
  end

  svcmgr.bind_supervisor()
  local order, err = svcmgr.start_all_autostart("/etc/services")
  if not order then
    log.error("init", "service ordering failed: " .. tostring(err))
    trace("autostart failed: " .. tostring(err))
  else
    log.info("init", "started services: " .. table.concat(order, ", "))
    trace("started: " .. table.concat(order, ", "))
  end

  while true do sched.sleep(60) end
end

return M
