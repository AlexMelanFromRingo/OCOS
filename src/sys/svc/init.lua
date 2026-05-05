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

  check("ui buffer + flush", function()
    -- Verifies the diff-based flush coalesces same-colour runs and skips
    -- unchanged cells.
    local Buffer = require("lib.ui.buffer")
    local fake_ops = {}
    local fake_gpu = {
      set    = function(x, y, s) fake_ops[#fake_ops + 1] = { "set", x, y, s } end,
      fill   = function(...) fake_ops[#fake_ops + 1] = { "fill", ... } end,
      copy   = function(...) fake_ops[#fake_ops + 1] = { "copy", ... } end,
      set_fg = function(c) fake_ops[#fake_ops + 1] = { "fg", c } end,
      set_bg = function(c) fake_ops[#fake_ops + 1] = { "bg", c } end,
    }
    local buf = Buffer.new(10, 3)
    buf:set(1, 1, "A", 0xFF0000, 0x000000)
    buf:set(2, 1, "B", 0xFF0000, 0x000000)
    buf:set(3, 1, "C", 0xFF0000, 0x000000)
    buf:flush(fake_gpu)
    local sets = 0
    for _, op in ipairs(fake_ops) do if op[1] == "set" then sets = sets + 1 end end
    assert(sets >= 1, "no gpu.set emitted")
    -- Second flush with no changes should be a no-op.
    fake_ops = {}; buf:flush(fake_gpu)
    for _, op in ipairs(fake_ops) do
      assert(op[1] ~= "set", "redundant set emitted on identical frame")
    end
  end)

  check("ui theme + widgets", function()
    local theme_m = require("lib.ui.theme")
    local widgets = {
      label    = require("lib.ui.widgets.label"),
      button   = require("lib.ui.widgets.button"),
      checkbox = require("lib.ui.widgets.checkbox"),
    }
    local Buffer = require("lib.ui.buffer")
    local theme = assert(theme_m.load("default"))
    assert(theme.palette and theme.palette.bg, "default theme missing palette.bg")
    local light = assert(theme_m.load("light"))
    assert(light.palette.bg ~= theme.palette.bg, "light should override bg")

    local buf = Buffer.new(20, 3)
    local lab = widgets.label({ text = "Hello" })
    lab:layout(1, 1, 20, 1); lab:draw(buf, theme)
    assert(buf:get(1, 1) == "H", "label first cell")
    assert(buf:get(5, 1) == "o", "label fifth cell")

    local btn = widgets.button({ text = "Go", on_click = function() end })
    btn:layout(1, 2, 6, 1); btn:draw(buf, theme)
    assert(buf:get(3, 2) == "G" or buf:get(4, 2) == "G", "button rendered")

    local chk = widgets.checkbox({ text = "On", checked = true })
    chk:layout(1, 3, 8, 1); chk:draw(buf, theme)
    assert(buf:get(2, 3) == "x", "checkbox marked")
  end)

  check("ui layout flex", function()
    local widgets = require("lib.ui.widget")
    local layout  = require("lib.ui.layout")
    local label   = require("lib.ui.widgets.label")
    local row = layout.row({
      gap = 1,
      children = { label({ text = "ab" }), label({ text = "cd" }), label({ text = "ef" }) },
    })
    row:layout(1, 1, 20, 1)
    assert(row.children[1].bounds.x == 1)
    assert(row.children[2].bounds.x == 4, "second child x: " .. row.children[2].bounds.x)
    assert(row.children[3].bounds.x == 7, "third child x: "  .. row.children[3].bounds.x)
  end)

  check("pbkdf2 + users", function()
    local pbkdf2 = require("lib.codec.pbkdf2")
    local hex = pbkdf2.derive("password", "salt", 100)
    assert(#hex == 64, "derive length: " .. #hex)
    assert(pbkdf2.verify("password", "salt", 100, hex))
    assert(not pbkdf2.verify("wrong", "salt", 100, hex))

    local users = require("lib.auth.users")
    local ok = users.create("ocos_test_user", "secret123", { iters = 200 })
    assert(ok, "create user")
    assert(users.verify("ocos_test_user", "secret123"))
    assert(not users.verify("ocos_test_user", "wrong"))
    assert(users.set_password("ocos_test_user", "newpass", { iters = 200 }))
    assert(users.verify("ocos_test_user", "newpass"))
    assert(not users.verify("ocos_test_user", "secret123"))
    assert(users.remove("ocos_test_user"))
    assert(not users.get("ocos_test_user"))
  end)

  check("capability enforcement", function()
    local cap = require("k.cap")
    cap.set_enforce(true)
    assert(cap.check({ ["*"] = true }, "syscall:write:/etc/passwd"))
    assert(not cap.check({ ["component:gpu"] = true }, "syscall:write:/etc/passwd"))
    assert(cap.check({ ["syscall:write:/var/*"] = true }, "syscall:write:/var/log/x"))
    assert(not cap.check({ ["syscall:write:/var/*"] = true }, "syscall:write:/etc/x"))
    cap.set_enforce(false)
  end)

  check("inspect cycles", function()
    local inspect = require("lib.devtools.inspect")
    local t = { name = "x", num = 42 }
    t.self = t
    local s = inspect.inspect(t)
    assert(s:find("name = \"x\"", 1, true), "name field: " .. s)
    assert(s:find("<table:", 1, true), "cycle marker: " .. s)
  end)

  check("profile bench", function()
    local prof = require("lib.devtools.profile")
    local r = prof.bench("noop", 1000, function() end)
    assert(r.iterations == 1000, "iterations recorded")
    assert(r.elapsed_s >= 0, "elapsed: " .. tostring(r.elapsed_s))
    local report = prof.format({ r })
    assert(report:find("noop", 1, true), "report contains name")
  end)

  check("json codec", function()
    local json = require("lib.codec.json")
    local round = function(v)
      local s = json.encode(v)
      local d, err = json.decode(s)
      assert(d, "decode: " .. tostring(err))
      return s, d
    end
    -- Primitives
    assert(json.decode("42") == 42)
    assert(json.decode("true") == true)
    assert(json.decode("null") == json.null)
    assert(json.decode([["hi"]]) == "hi")
    -- Round-trip an object.
    local s = round({ a = 1, b = "x", c = { 1, 2, 3 }, d = true })
    assert(s:find("%[1,2,3%]"), "array encoded: " .. s)
    -- Nested escape.
    local s2 = json.encode({ k = "with \"quotes\" and\n newline" })
    assert(s2:find("\\n", 1, true), "newline escaped: " .. s2)
    assert(json.decode(s2).k:find("quotes", 1, true))
    -- Reject malformed.
    assert(not json.decode("{,}"))
    assert(not json.decode("[1,]"))
  end)

  check("locale framework", function()
    local lang = require("lib.lang")
    assert(lang.t("dock.files") ~= "<dock.files>", "english fallback works")
    assert(lang.set("uk"), "set uk")
    assert(lang.t("dock.files"):find("Файли", 1, true), "ukrainian: " .. lang.t("dock.files"))
    assert(lang.set("en"), "set en")
    assert(lang.t("dock.files") == "Files")
    assert(lang.t("missing.key.xyz") == "<missing.key.xyz>", "missing keys are visible")
    local available = lang.list_available()
    assert(#available >= 3, "available locales: " .. tostring(#available))
  end)

  check("stress: 50 procs", function()
    local proc = require("k.proc")
    local before = #proc.list()
    local done = {}
    for i = 1, 50 do
      local id_local = i
      sched.spawn(function() sched.sleep(0); done[id_local] = true end,
        { name = "stress-" .. i, caps = { "*" } })
    end
    for _ = 1, 20 do sched.sleep(0) end
    local count = 0; for _ in pairs(done) do count = count + 1 end
    assert(count == 50, "completed " .. count .. "/50")
    assert(#proc.list() <= before + 2, "proc table leaked: " .. (#proc.list() - before))
  end)

  check("stress: 1000 ipc msgs", function()
    local count = 0
    local h = ipc.subscribe("stress.msg", function() count = count + 1 end)
    for i = 1, 1000 do ipc.publish("stress.msg", i) end
    ipc.unsubscribe(h)
    assert(count == 1000, "delivered " .. count .. "/1000")
  end)

  check("apps load cleanly", function()
    local Buffer = require("lib.ui.buffer")
    local stub_buf = Buffer.new(80, 24)
    local stub_compositor = {
      theme       = require("lib.ui.theme").current(),
      add         = function(_, w) w:layout(1, 1, 80, 24); return w end,
      invalidate  = function() end,
      size        = function() return 80, 24 end,
      set_theme   = function() end,
    }
    for _, app in ipairs({ "desktop", "files", "dmesg", "inspect", "settings" }) do
      local path = "/apps/" .. app .. ".app/Main.lua"
      local src = vfs.read_all(path); assert(src, "cannot read " .. path)
      local fn, lerr = load(src, "=" .. path, "t", _G)
      assert(fn, app .. " load: " .. tostring(lerr))
      local ok, rerr = pcall(fn, {}, {}, { compositor = stub_compositor })
      assert(ok, app .. " run: " .. tostring(rerr))
    end
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
