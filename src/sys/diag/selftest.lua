-- /sys/diag/selftest.lua — boot-time self-test battery.
--
-- Lives outside the always-loaded svc/init.lua so its 500 lines of
-- bytecode don't bloat the kernel chunk on production boots. init.lua
-- only requires this module when /etc/boot.selftest is present; the
-- chunk runs once and shuts the machine down.

local M = {}

function M.run()
  local sched   = require("k.sched")
  local log     = require("k.log")
  local vfs     = require("k.vfs")
  local exec    = require("k.exec")
  local ipc     = require("k.ipc")
  local console = require("lib.term.console")
  local svcmgr  = require("lib.svc.manager")
  local users   = require("lib.auth.users")

  local function find_writable_mount()
    for _, m in ipairs(vfs.mounts()) do
      if m.prefix:sub(1, 5) == "/mnt/" then return m.prefix end
    end
  end

  local results = { _OSVERSION, "uptime=" .. tostring(computer.uptime()) }
  local function check(name, fn)
    local ok, err = pcall(fn)
    if not ok and type(err) == "string" and err:find("^skip:") then
      results[#results + 1] = "SKIP " .. name .. "  -- " .. err:sub(6)
    else
      results[#results + 1] = (ok and "PASS " or "FAIL ") .. name ..
        (ok and "" or "  -- " .. tostring(err))
    end
  end
  local function skip_if(cond, reason)
    if cond then error("skip:" .. (reason or ""), 0) end
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

  check("fs cli (mkdir/rm/cp/mv/touch)", function()
    local mp = find_writable_mount(); assert(mp, "no writable mount")
    shell_capture("rm -rf " .. mp .. "/citest")
    -- Each command separately so we can pinpoint a failure.
    local function run(cmd)
      local o = shell_capture(cmd)
      assert(o == "" or not o:find("error", 1, true) or not o:find(":", 1, true),
        "step `" .. cmd .. "` reported: " .. o)
      return o
    end
    run("mkdir -p " .. mp .. "/citest/sub")
    run("touch "    .. mp .. "/citest/a")
    run("echo hi > ".. mp .. "/citest/b")
    assert(vfs.exists(mp .. "/citest/b"), "echo redirect did not create b")
    run("cp " .. mp .. "/citest/b " .. mp .. "/citest/sub/b")
    assert(vfs.exists(mp .. "/citest/sub/b"),
      "cp did not produce sub/b. sub list: " ..
      table.concat(vfs.list(mp .. "/citest/sub") or {}, ","))
    run("mv " .. mp .. "/citest/sub/b " .. mp .. "/citest/sub/c")
    assert(vfs.exists(mp .. "/citest/sub/c"), "destination missing after mv")
    assert(not vfs.exists(mp .. "/citest/sub/b"), "source still present after mv")
    shell_capture("rm -rf " .. mp .. "/citest")
    assert(not vfs.exists(mp .. "/citest"), "rm -rf left dir behind")
  end)

  check("kill cooperative TERM", function()
    local proc = require("k.proc")
    local got_term
    local handle = ipc.subscribe("proc.term", function(p) got_term = p.pid end)
    local victim = sched.spawn(function()
      while true do sched.sleep(0.05) end
    end, { name = "kill-test", caps = { "*" } })
    proc.kill(victim.id, "term")
    sched.sleep(0.1)
    ipc.unsubscribe(handle)
    assert(got_term == victim.id, "term ipc not seen for pid " .. victim.id)
    proc.kill(victim.id, "kill")
    sched.sleep(0.05)
    assert(not proc.get(victim.id), "victim still in proc table after SIGKILL")
  end)

  check("vfs symlinks", function()
    local mp = find_writable_mount(); assert(mp, "no writable mount")
    local target = mp .. "/sym-target.txt"
    local link   = mp .. "/sym-link.txt"
    pcall(vfs.remove, target)
    pcall(vfs.remove, link)
    assert(vfs.write_all(target, "OCOSSYMLINK"), "write target")
    assert(vfs.symlink(target, link), "create symlink")
    assert(vfs.is_symlink(link), "is_symlink should be true")
    assert(vfs.readlink(link) == target, "readlink mismatch")
    assert(vfs.read_all(link) == "OCOSSYMLINK", "follow on read")
    assert(vfs.exists(link), "exists should follow link")
    assert(vfs.remove(link), "remove link")
    assert(vfs.exists(target), "removing link removed target!")
    pcall(vfs.remove, target)
  end)

  check("modem self-broadcast", function()
    skip_if(not component.list("modem")(), "no modem")
    local modem = require("drv.modem")
    modem.init()
    local PORT = 49001
    modem.open(PORT)
    local got
    local handle = ipc.subscribe("net.message", function(msg)
      if msg.port == PORT then got = msg end
    end)
    modem.broadcast(PORT, "ocos-net-test", 7)
    local deadline = computer.uptime() + 2
    while not got and computer.uptime() < deadline do sched.sleep(0.05) end
    ipc.unsubscribe(handle); modem.close(PORT)
    assert(got, "did not receive own broadcast within 2s")
    assert(got.payload[1] == "ocos-net-test", "payload mismatch: " .. tostring(got.payload[1]))
    assert(got.payload[2] == 7, "payload[2] mismatch: " .. tostring(got.payload[2]))
  end)

  check("internet HTTP GET", function()
    local net = require("drv.internet")
    skip_if(not net.has_internet(), "no internet card")
    local body, status = net.http_request("https://example.com/", { timeout = 10 })
    assert(body, "request failed: " .. tostring(status))
    assert(body:lower():find("example", 1, true), "body did not mention example")
  end)

  check("uid service stays running", function()
    local gpu = require("drv.gpu")
    local gw, gh = gpu.size()
    skip_if(not gw or gw <= 0 or not gh or gh <= 0, "headless gpu (0x0)")
    svcmgr.load_units("/etc/services")
    local svc = svcmgr.start("uid")
    if not svc then error("could not start uid") end
    sched.sleep(0.5)
    local s = svcmgr.status("uid")
    assert(s and s.state == "running",
      "uid is " .. tostring(s and s.state) .. " (last_error=" ..
      tostring(s and s.last_error) .. ")")
    pcall(svcmgr.stop, "uid")
    sched.sleep(0.2)
  end)

  check("sessiond suspend/resume", function()
    local released, acquired
    local h1 = ipc.subscribe("ses.tty.released", function() released = true end)
    local h2 = ipc.subscribe("ses.tty.acquired", function() acquired = true end)
    svcmgr.load_units("/etc/services")
    local svc = svcmgr.start("sessiond")
    assert(svc, "could not start sessiond")
    sched.sleep(0.2)
    ipc.publish("svc.suspend.sessiond", true)
    sched.sleep(0.3)
    assert(released, "sessiond did not publish ses.tty.released on suspend")
    ipc.publish("svc.resume.sessiond", true)
    sched.sleep(0.3)
    assert(acquired, "sessiond did not publish ses.tty.acquired on resume")
    ipc.unsubscribe(h1); ipc.unsubscribe(h2)
    pcall(svcmgr.stop, "sessiond")
  end)

  check("sha256 vectors", function()
    local sha = require("lib.codec.sha256")
    assert(sha.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    assert(sha.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    local long = string.rep("OCOS", 16384)
    assert(#sha.hex(long) == 64)
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

  check("chacha20 + poly1305 + sha512 vectors", function()
    local function hex(s)
      s = s:gsub("%s", "")
      local out = {}
      for i = 1, #s, 2 do out[#out+1] = string.char(tonumber(s:sub(i, i+1), 16)) end
      return table.concat(out)
    end
    local chacha = require("lib.codec.chacha20")
    local key = ""
    for i = 0, 31 do key = key .. string.char(i) end
    local nonce = hex("000000000000004a00000000")
    local pt = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
    local expected = hex(
      "6e2e359a2568f98041ba0728dd0d6981" ..
      "e97e7aec1d4360c20a27afccfd9fae0b" ..
      "f91b65c5524733ab8f593dabcd62b357" ..
      "1639d624e65152ab8f530c359f0861d8" ..
      "07ca0dbf500d6a6156a38e088a22b65e" ..
      "52bc514d16ccf806818ce91ab7793736" ..
      "5af90bbf74a35be6b40b8eedf2785e42" ..
      "874d")
    assert(chacha.encrypt(key, nonce, pt, 1) == expected, "chacha20 vector")
    assert(chacha.decrypt(key, nonce, expected, 1) == pt, "chacha20 round-trip")

    local poly = require("lib.codec.poly1305")
    local pkey = hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
    assert(poly.mac(pkey, "Cryptographic Forum Research Group") ==
      hex("a8061dc1305136c6c22b8baf0c0127a9"), "poly1305 vector")

    local sha512 = require("lib.codec.sha512")
    assert(sha512.hex("abc") ==
      "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
      .. "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
  end)

  check("ui buffer + flush", function()
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
    local layout = require("lib.ui.layout")
    local label  = require("lib.ui.widgets.label")
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
    assert(#hex == 64)
    assert(pbkdf2.verify("password", "salt", 100, hex))
    assert(not pbkdf2.verify("wrong", "salt", 100, hex))
    assert(users.create("ocos_test_user", "secret123", { iters = 200 }))
    assert(users.verify("ocos_test_user", "secret123"))
    assert(not users.verify("ocos_test_user", "wrong"))
    assert(users.set_password("ocos_test_user", "newpass", { iters = 200 }))
    assert(users.verify("ocos_test_user", "newpass"))
    assert(users.remove("ocos_test_user"))
  end)

  check("multi-user defaults (admin / limited)", function()
    local cap = require("k.cap")
    assert(users.create("ocos_admin_t", "admin1234", { iters = 100, role = "admin" }))
    assert(users.is_admin("ocos_admin_t"), "admin should be admin")
    local arec = users.get("ocos_admin_t")
    assert(cap.check(cap.expand_set(arec.caps), "syscall:write:/etc/passwd"))
    assert(users.remove("ocos_admin_t"))

    assert(users.create("ocos_limited_t", "limit1234", { iters = 100 }))
    assert(not users.is_admin("ocos_limited_t"), "limited should not be admin")
    local lrec = users.get("ocos_limited_t")
    local lset = cap.expand_set(lrec.caps)
    cap.set_enforce(true)
    assert(cap.check(lset, "syscall:exec"), "exec allowed")
    assert(cap.check(lset, "syscall:write:/home/ocos_limited_t/file"), "home write")
    assert(not cap.check(lset, "syscall:write:/etc/passwd"), "/etc write denied")
    assert(not cap.check(lset, "syscall:write:/sys/k/cap.lua"), "/sys write denied")
    assert(cap.check(lset, "component:gpu"), "gpu access")
    cap.set_enforce(false)
    assert(users.remove("ocos_limited_t"))
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
    local t = { name = "x", num = 42 }; t.self = t
    local s = inspect.inspect(t)
    assert(s:find("name = \"x\"", 1, true), "name field: " .. s)
    assert(s:find("<table:", 1, true), "cycle marker: " .. s)
  end)

  check("profile bench", function()
    local prof = require("lib.devtools.profile")
    local r = prof.bench("noop", 1000, function() end)
    assert(r.iterations == 1000)
    assert(r.elapsed_s >= 0)
    assert(prof.format({ r }):find("noop", 1, true))
  end)

  check("json codec", function()
    local json = require("lib.codec.json")
    assert(json.decode("42") == 42)
    assert(json.decode("true") == true)
    assert(json.decode("null") == json.null)
    assert(json.decode([["hi"]]) == "hi")
    local s = json.encode({ a = 1, b = "x", c = { 1, 2, 3 }, d = true })
    assert(s:find("%[1,2,3%]"))
    local s2 = json.encode({ k = "with \"quotes\" and\n newline" })
    assert(s2:find("\\n", 1, true))
    assert(json.decode(s2).k:find("quotes", 1, true))
    assert(not json.decode("{,}"))
    assert(not json.decode("[1,]"))
  end)

  check("locale framework", function()
    local lang = require("lib.lang")
    assert(lang.t("dock.files") ~= "<dock.files>")
    assert(lang.set("uk"))
    assert(lang.t("dock.files"):find("Файли", 1, true))
    assert(lang.set("en"))
    assert(lang.t("dock.files") == "Files")
    assert(lang.t("missing.key.xyz") == "<missing.key.xyz>")
    assert(#lang.list_available() >= 3)
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
    local src_dir = mp .. "/pkg-test-src"
    local dst_root = mp .. "/pkg-test-dst/"
    pcall(vfs.mkdir, src_dir)
    pcall(vfs.mkdir, src_dir .. "/lib")
    pcall(vfs.mkdir, mp .. "/pkg-test-dst")
    local payload = "return function() return 'hello-from-pkg' end\n"
    vfs.write_all(src_dir .. "/lib/hello.lua", payload)
    local digest = sha.hex(payload)
    vfs.write_all(src_dir .. "/manifest.cfg", string.format([[
return {
  id = "ocos.test.hello",
  name = "Hello",
  version = "0.1.0",
  description = "self-test package",
  prefix = %q,
  files = { ["lib/hello.lua"] = { sha256 = %q } },
}
]], dst_root, digest))
    local mfst, err = install.install_dir(src_dir)
    assert(mfst, "install: " .. tostring(err))
    assert(vfs.exists(dst_root .. "lib/hello.lua"), "destination file missing")
    assert(install.verify("ocos.test.hello"), "verify after install")
    vfs.write_all(dst_root .. "lib/hello.lua", payload .. "garbage")
    assert(not install.verify("ocos.test.hello"), "verify must fail on tampered file")
    vfs.write_all(dst_root .. "lib/hello.lua", payload)
    assert(install.verify("ocos.test.hello"), "post-restore verify failed")
    assert(install.uninstall("ocos.test.hello"))
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

return M
