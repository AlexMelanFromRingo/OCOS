-- /sys/svc/init.lua — first user process. Spawns the shell.

local M = {}

local sched = require("k.sched")
local log   = require("k.log")
local term  = require("lib.term.console")
local vfs   = require("k.vfs")

local function load_shell()
  local src, err = vfs.read_all("/bin/sh.lua")
  if not src then return nil, err end
  return load(src, "=/bin/sh.lua", "t", _G)
end

local function dump_dmesg_to_writable()
  -- Walk vfs.mounts() and pick any non-boot, non-tmpfs prefix to drop a
  -- dmesg.log into. Used as a postboot trace until the real GUI can show it.
  for _, m in ipairs(vfs.mounts()) do
    if m.prefix:sub(1, 5) == "/mnt/" then
      local path = m.prefix .. "/dmesg.log"
      local lines = { _OSVERSION, "boot at uptime " .. tostring(computer.uptime()) }
      for _, e in ipairs(log.entries()) do
        lines[#lines + 1] = string.format("[%8.3f] %s %s: %s", e.time, e.level, e.tag, e.msg)
      end
      vfs.write_all(path, table.concat(lines, "\n") .. "\n")
      log.info("init", "wrote " .. path)
      return
    end
  end
end

-- Self-test mode: when /etc/boot.selftest exists, run a short boot-up test,
-- write results to /selftest.log on the writable fs, then shut down. Used
-- by tools/test-boot.sh to validate the kernel without needing a real tty.
local function selftest_active()
  return vfs.exists("/etc/boot.selftest")
end

local function append_writable(path, text)
  for _, m in ipairs(vfs.mounts()) do
    if m.prefix:sub(1, 5) == "/mnt/" then
      vfs.write_all(m.prefix .. path, text)
      return m.prefix .. path
    end
  end
  return nil
end

local function selftest_run()
  local results = { _OSVERSION, "uptime=" .. tostring(computer.uptime()) }
  local function ok(name, fn)
    if _G._BOOT_TRACE then _G._BOOT_TRACE("selftest start: " .. name) end
    local good, err = pcall(fn)
    if _G._BOOT_TRACE then _G._BOOT_TRACE("selftest done : " .. name .. " -> " .. (good and "PASS" or "FAIL " .. tostring(err))) end
    results[#results + 1] = (good and "PASS " or "FAIL ") .. name ..
      (good and "" or "  -- " .. tostring(err))
  end
  ok("vfs.list /sys",   function() assert(#vfs.list("/sys") > 0) end)
  ok("vfs.list /bin",   function() assert(#vfs.list("/bin") > 0) end)
  ok("vfs read /init",  function() local s=vfs.read_all("/init.lua"); assert(s and #s>0) end)
  ok("sched.sleep(0)",  function() sched.sleep(0) end)
  ok("ipc echo",        function()
    local ipc = require("k.ipc")
    local got
    local h = ipc.subscribe("test.echo", function(p) got = p end)
    ipc.publish("test.echo", { v = 42 })
    ipc.unsubscribe(h)
    assert(got and got.v == 42, "echo failed")
  end)
  ok("term.init",       function() term.init() end)
  ok("gpu writeln",     function() term.writeln(_OSVERSION) end)
  for _, e in ipairs(log.entries()) do
    results[#results + 1] = string.format("[%8.3f] %s %s: %s", e.time, e.level, e.tag, e.msg)
  end
  local path = append_writable("/selftest.log", table.concat(results, "\n") .. "\n")
  log.info("selftest", "wrote " .. tostring(path))
  if _G._BOOT_TRACE then _G._BOOT_TRACE("selftest done writing, shutting down") end
  sched.sleep(0.1)
  computer.shutdown(false)
end

function M.main()
  log.info("init", "init service starting")
  if selftest_active() then return selftest_run() end
  term.init()
  term.writeln(_OSVERSION)
  term.writeln("type `help` for the command list")
  term.writeln("")
  dump_dmesg_to_writable()
  while true do
    local sh, err = load_shell()
    if not sh then
      term.writeln("init: cannot load /bin/sh.lua: " .. tostring(err))
      log.error("init", "cannot load shell: " .. tostring(err))
      sched.sleep(2)
    else
      sched.spawn(sh, { name = "sh", caps = { "*" } })
      -- Wait for the shell process to exit, then loop to restart it.
      local _ = sched.wait(function(name) return name == "__never__" end, 3600)
      dump_dmesg_to_writable()
    end
  end
end

return M
