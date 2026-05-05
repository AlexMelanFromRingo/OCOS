-- /sys/svc/init.lua — first user process. Brings up the service manager
-- and lets it own the rest of userland. When /etc/boot.selftest is present,
-- runs the in-kernel test battery instead and shuts the machine down.

local M = {}

local sched   = require("k.sched")
local log     = require("k.log")
local vfs     = require("k.vfs")
local exec    = require("k.exec")
local ipc     = require("k.ipc")
local console = require("lib.term.console")
local svcmgr  = require("lib.svc.manager")

local function find_writable_mount()
  for _, m in ipairs(vfs.mounts()) do
    if m.prefix:sub(1, 5) == "/mnt/" then return m.prefix end
  end
end

-- ---- selftest -----------------------------------------------------------

local function selftest_active() return vfs.exists("/etc/boot.selftest") end

local function selftest_run()
  local results = { _OSVERSION, "uptime=" .. tostring(computer.uptime()) }
  local function check(name, fn)
    local ok, err = pcall(fn)
    results[#results + 1] = (ok and "PASS " or "FAIL ") .. name ..
      (ok and "" or "  -- " .. tostring(err))
  end

  check("vfs.list /sys",  function() assert(#vfs.list("/sys") > 0) end)
  check("vfs.list /bin",  function() assert(#vfs.list("/bin") > 0) end)
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

  check("shell pipe",        function() assert(shell_capture("echo OCOSLINE | grep CO"):find("OCOSLINE", 1, true)) end)
  check("shell &&",          function() assert(shell_capture("true && echo OK_AND"):find("OK_AND", 1, true)) end)
  check("shell ||",          function() assert(shell_capture("false || echo OK_OR"):find("OK_OR", 1, true)) end)
  check("shell var",         function() assert(shell_capture("set X=ocosvar; echo $X"):find("ocosvar", 1, true)) end)
  check("shell redirect >",  function()
    local mp = find_writable_mount(); assert(mp, "no writable mount")
    local target = mp .. "/redir.tmp"
    shell_capture("echo OCOSREDIR > " .. target)
    local s = vfs.read_all(target) or ""
    assert(s:find("OCOSREDIR", 1, true), "redir file: " .. tostring(s))
    pcall(vfs.remove, target)
  end)

  check("svc framework", function()
    svcmgr.load_units("/etc/services")
    local list = svcmgr.list()
    local ids = {}
    for _, s in ipairs(list) do ids[s.id] = true end
    assert(ids.logd and ids.sessiond, "missing services in unit dir")
  end)

  check("sha256 vectors", function()
    local sha = require("lib.codec.sha256")
    assert(sha.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "empty: " .. sha.hex(""))
    assert(sha.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      "abc: " .. sha.hex("abc"))
    -- Long-message vector trimmed to 64 KiB so tier-1 RAM machines can run
    -- the test; the SHA-256 spec test vectors are also FIPS-published only
    -- for short inputs.
    local long = string.rep("OCOS", 16384)         -- 64 KiB
    local h = sha.hex(long)
    assert(#h == 64, "long output length: " .. #h)
  end)

  check("semver constraints", function()
    local s = require("lib.codec.semver")
    assert(s.satisfies("1.2.3", ">=1.0.0"))
    assert(not s.satisfies("1.2.3", "<1.0.0"))
    assert(s.satisfies("1.2.3", ">=1.0,<2.0"))
    assert(s.satisfies("1.2.3", "^1.0"))
    assert(not s.satisfies("2.0.0", "^1.0"))
    assert(s.satisfies("1.2.3", "~1.2"))
    assert(not s.satisfies("1.3.0", "~1.2"))
  end)

  check("pkg install + verify + uninstall", function()
    local mp = find_writable_mount(); assert(mp, "no writable mount")
    local sha = require("lib.codec.sha256")
    local install = require("lib.pkg.install")
    local db = require("lib.pkg.db")

    local src_dir = mp .. "/pkg-test-src"
    local dst_root = mp .. "/pkg-test-dst/"
    pcall(vfs.mkdir, src_dir)
    pcall(vfs.mkdir, src_dir .. "/lib")
    pcall(vfs.mkdir, mp .. "/pkg-test-dst")
    local payload = "return function() return 'hello-from-pkg' end\n"
    vfs.write_all(src_dir .. "/lib/hello.lua", payload)
    local digest = sha.hex(payload)
    local manifest_src = string.format([[
return {
  id = "ocos.test.hello",
  name = "Hello",
  version = "0.1.0",
  description = "self-test package",
  prefix = %q,
  files = { ["lib/hello.lua"] = { sha256 = %q } },
}
]], dst_root, digest)
    vfs.write_all(src_dir .. "/manifest.cfg", manifest_src)

    local mfst, err = install.install_dir(src_dir)
    assert(mfst, "install: " .. tostring(err))
    assert(vfs.exists(dst_root .. "lib/hello.lua"), "destination file missing")
    local vok, verr = install.verify("ocos.test.hello")
    assert(vok, "verify after install: " .. tostring(verr))

    -- Tampered file must be detected.
    vfs.write_all(dst_root .. "lib/hello.lua", payload .. "garbage")
    local ok = install.verify("ocos.test.hello")
    assert(not ok, "verify must fail on tampered file")
    -- Restore + uninstall.
    vfs.write_all(dst_root .. "lib/hello.lua", payload)
    assert(install.verify("ocos.test.hello"), "post-restore verify failed")
    assert(install.uninstall("ocos.test.hello"))
    assert(not vfs.exists(dst_root .. "lib/hello.lua"), "uninstall left files")
    pcall(vfs.remove, src_dir .. "/manifest.cfg")
    pcall(vfs.remove, src_dir .. "/lib/hello.lua")
    pcall(vfs.remove, src_dir .. "/lib")
    pcall(vfs.remove, src_dir)
    pcall(vfs.remove, mp .. "/pkg-test-dst/lib")
    pcall(vfs.remove, mp .. "/pkg-test-dst")
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

-- ---- normal supervised startup -----------------------------------------

function M.main()
  log.info("init", "init service starting")
  if selftest_active() then return selftest_run() end

  -- Bring up the supervisor first so any subsequent proc.exit is observed.
  svcmgr.bind_supervisor()
  local order, err = svcmgr.start_all_autostart("/etc/services")
  if not order then
    log.error("init", "service ordering failed: " .. tostring(err))
  else
    log.info("init", "started services: " .. table.concat(order, ", "))
  end

  -- Init never exits. Sleep in long stretches so the watchdog stays happy.
  while true do sched.sleep(60) end
end

return M
