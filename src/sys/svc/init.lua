-- /sys/svc/init.lua — first user process. Brings up the console, prints
-- the MOTD, spawns a login shell, and respawns it whenever it exits.
--
-- When /etc/boot.selftest exists, init runs the boot-time test suite
-- instead and shuts the machine down — that path is exercised by
-- tools/test-boot.sh in the host development environment.

local M = {}

local sched   = require("k.sched")
local log     = require("k.log")
local vfs     = require("k.vfs")
local exec    = require("k.exec")
local console = require("lib.term.console")
local tty     = require("lib.term.tty")
local ipc     = require("k.ipc")

local function find_writable_mount()
  for _, m in ipairs(vfs.mounts()) do
    if m.prefix:sub(1, 5) == "/mnt/" then return m.prefix end
  end
end

local function default_streams()
  return { stdin = tty.stdin(), stdout = tty.stdout(), stderr = tty.stderr() }
end

local function print_motd(streams)
  if vfs.exists("/etc/motd") then
    local h = vfs.open("/etc/motd", "r")
    if h then
      while true do
        local chunk = h:read(4096); if not chunk or chunk == "" then break end
        streams.stdout:write(chunk)
      end
      h:close()
    end
  end
end

-- ---- self-test ----------------------------------------------------------

local function selftest_active() return vfs.exists("/etc/boot.selftest") end

local function selftest_run()
  local results = { _OSVERSION, "uptime=" .. tostring(computer.uptime()) }
  local function check(name, fn)
    local ok, err = pcall(fn)
    results[#results + 1] = (ok and "PASS " or "FAIL ") .. name ..
      (ok and "" or "  -- " .. tostring(err))
  end
  check("vfs.list /sys", function() assert(#vfs.list("/sys") > 0) end)
  check("vfs.list /bin", function() assert(#vfs.list("/bin") > 0) end)
  check("vfs read /init", function() local s = vfs.read_all("/init.lua"); assert(s and #s > 0) end)
  check("sched.sleep(0)", function() sched.sleep(0) end)
  check("ipc echo",       function()
    local got
    local h = ipc.subscribe("test.echo", function(p) got = p end)
    ipc.publish("test.echo", { v = 42 })
    ipc.unsubscribe(h)
    assert(got and got.v == 42, "echo failed")
  end)
  check("term.init",   function() console.init() end)
  check("gpu writeln", function() console.writeln(_OSVERSION) end)
  local function shell_capture(script)
    local pipe   = require("std.pipe")
    local stream = require("std.stream")
    local r, w = pipe.new()
    local p = exec.exec("/bin/sh.lua", { "-c", script }, {
      streams   = { stdin = stream.null(), stdout = w, stderr = w },
      shell_env = { PATH = "/bin", PWD = "/" },
      caps = { "*" }, name = "sh-test",
    })
    assert(p, "exec.exec failed")
    sched.wait_pid(p.id)
    pcall(w.close, w)
    return r:read("a") or ""
  end

  check("shell pipe", function()
    local out = shell_capture("echo OCOSLINE | grep CO")
    assert(out:find("OCOSLINE", 1, true), "pipeline output: " .. tostring(out))
  end)
  check("shell &&", function()
    local out = shell_capture("true && echo OK_AND")
    assert(out:find("OK_AND", 1, true), "&& output: " .. tostring(out))
  end)
  check("shell ||", function()
    local out = shell_capture("false || echo OK_OR")
    assert(out:find("OK_OR", 1, true), "|| output: " .. tostring(out))
  end)
  check("shell redirect >", function()
    local mp = find_writable_mount(); assert(mp, "no writable mount")
    local target = mp .. "/redir.tmp"
    shell_capture("echo OCOSREDIR > " .. target)
    local s = vfs.read_all(target) or ""
    assert(s:find("OCOSREDIR", 1, true), "redir file: " .. tostring(s))
    pcall(vfs.remove, target)
  end)
  check("shell var", function()
    local out = shell_capture("set X=ocosvar; echo $X")
    assert(out:find("ocosvar", 1, true), "var output: " .. tostring(out))
  end)

  for _, e in ipairs(log.entries()) do
    results[#results + 1] = string.format("[%8.3f] %s %s: %s", e.time, e.level, e.tag, e.msg)
  end
  local mp = find_writable_mount()
  if mp then vfs.write_all(mp .. "/selftest.log", table.concat(results, "\n") .. "\n") end
  log.info("selftest", "wrote selftest.log; shutting down")
  sched.sleep(0.1)
  computer.shutdown(false)
end

-- ---- normal boot --------------------------------------------------------

local function spawn_shell(streams)
  return exec.exec("/bin/sh.lua", {}, {
    streams   = streams,
    shell_env = { PATH = "/bin", PWD = "/", HOME = "/home", USER = "root" },
    caps      = { "*" },
    name      = "sh",
  })
end

function M.main()
  log.info("init", "init service starting")
  if selftest_active() then return selftest_run() end

  console.init()
  local streams = default_streams()
  console.set_fg(0xCCCCFF)
  console.writeln(_OSVERSION)
  console.set_fg(0xCCCCCC)
  print_motd(streams)
  console.writeln("")

  while true do
    local sh, err = spawn_shell(streams)
    if not sh then
      streams.stderr:write("init: cannot launch shell: " .. tostring(err) .. "\n")
      log.error("init", "cannot launch shell: " .. tostring(err))
      sched.sleep(2)
    else
      sched.wait_pid(sh.id)
      console.writeln("")
      console.writeln("[shell exited; restarting in 1s]")
      sched.sleep(1)
    end
  end
end

return M
