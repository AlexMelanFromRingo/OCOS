-- /sys/svc/init.lua — first user process.
--
-- Boot flow:
--   1. If /etc/boot.selftest exists, delegate to the in-OS test battery
--      and shut down. This keeps the always-loaded kernel chunk small.
--   2. Pick a boot mode:
--        explicit pin from /etc/boot.cfg ({ mode = ... }) wins;
--        otherwise show a 2-second "press any key for menu" prompt and
--        fall through to "console" if the user does nothing.
--   3. Start services + run mode-specific main:
--        console → logd + sessiond (TTY shell)
--        gui     → logd + sessiond, then svcmgr.start("uid") with a
--                  300 ms gap so sessiond is in wait_pid by the time
--                  uid suspends its child shell (this is the same
--                  sequence as a user typing `svc start uid` from the
--                  TTY — race-free because active_sh is already set)
--        safe    → only logd; init owns the recovery shell directly

local M = {}

local sched   = require("k.sched")
local log     = require("k.log")
local vfs     = require("k.vfs")
local exec    = require("k.exec")
local console = require("lib.term.console")
local svcmgr  = require("lib.svc.manager")

local trace = require("lib.diag.trace").for_name("init")

local function read_pinned_mode()
  if not vfs.exists("/etc/boot.cfg") then return end
  local src = vfs.read_all("/etc/boot.cfg")
  if not src then return end
  local fn = load(src, "=/etc/boot.cfg", "t", {})
  if not fn then return end
  local ok, t = pcall(fn)
  if not ok or type(t) ~= "table" or not t.mode then return end
  return tostring(t.mode)
end

local BOOT_TIMEOUT  = 3
local DEFAULT_MODE  = "console"

local function choose_mode_from_user()
  local gpu = require("drv.gpu")
  console.init()
  console.set_fg(0xCCCCFF); console.writeln(_OSVERSION)
  console.set_fg(0xCCCCCC); console.writeln("")
  console.writeln("Boot menu:")
  console.writeln("  1) Console — TTY shell (default)")
  console.writeln("  2) Desktop — GUI compositor")
  console.writeln("  3) Safe   — recovery shell, no services")
  console.writeln("")

  -- Animated countdown bar over BOOT_TIMEOUT seconds. Polling every
  -- 0.1 s; bar is 28 cells wide so each tick clears one. Pressing
  -- 1/2/3 short-circuits; pressing anything else cancels the timer
  -- and waits for an explicit choice.
  local bar_x, bar_y, bar_w = 2, ({console.cursor()})[2], 28
  console.writeln(""); console.writeln("")

  local function paint_bar(remaining)
    local fg = console.fg()
    console.set_fg(0x666666)
    gpu.set(bar_x, bar_y, "[" .. string.rep(" ", bar_w) .. "]")
    local filled = math.floor(bar_w * remaining / BOOT_TIMEOUT + 0.5)
    if filled > 0 then
      console.set_fg(0x4FA0F0)
      gpu.set(bar_x + 1, bar_y, string.rep("=", filled))
    end
    console.set_fg(0x888888)
    gpu.set(bar_x + bar_w + 3, bar_y,
      string.format("default: %s in %.1fs ", DEFAULT_MODE, remaining))
    console.set_fg(fg)
  end

  local function decode_key(ev)
    local _, char, code = ev.args[1], ev.args[2], ev.args[3]
    if char == 49 or code == 28 then return "console" end
    if char == 50 then                return "gui"     end
    if char == 51 then                return "safe"    end
  end

  local deadline = computer.uptime() + BOOT_TIMEOUT
  while true do
    local rem = deadline - computer.uptime()
    if rem <= 0 then return DEFAULT_MODE end
    paint_bar(rem)
    local poll = math.min(rem, 0.1)
    local ev = sched.wait(function(n) return n == "key_down" end, poll)
    if ev then
      local mode = decode_key(ev)
      if mode then return mode end
      -- Other key: cancel timer, wait for explicit 1/2/3.
      console.set_fg(0xCCCCCC)
      gpu.set(bar_x, bar_y, "press 1/2/3 (Enter = console)" .. string.rep(" ", 30))
      while true do
        local kev = sched.wait(function(n) return n == "key_down" end)
        if kev then
          local m = decode_key(kev)
          if m then return m end
        end
      end
    end
  end
end

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
    caps      = { "*" }, name = "sh:safe",
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
  trace("init.main; _OSVERSION=" .. tostring(_OSVERSION))

  if vfs.exists("/etc/boot.selftest") then
    return require("diag.selftest").run()
  end

  local mode = read_pinned_mode() or choose_mode_from_user()
  log.info("init", "boot mode: " .. mode)
  trace("boot mode: " .. mode)

  svcmgr.bind_supervisor()

  if mode == "safe" then
    svcmgr.load_units("/etc/services")
    svcmgr.set_unit_autostart("sessiond", false)
    svcmgr.set_unit_autostart("uid", false)
    svcmgr.start_autostart()
    return safe_mode_main()
  end

  local order, err = svcmgr.start_all_autostart("/etc/services")
  if not order then
    log.error("init", "service ordering failed: " .. tostring(err))
    trace("autostart failed: " .. tostring(err))
  else
    log.info("init", "started services: " .. table.concat(order, ", "))
    trace("started: " .. table.concat(order, ", "))
  end

  if mode == "gui" then
    -- Let sessiond paint its banner and reach wait_pid before uid asks
    -- it to pause. Mirrors the user-typed `svc start uid` sequence
    -- which works reliably from the TTY.
    sched.sleep(0.3)
    local ok, e = svcmgr.start("uid")
    if not ok then
      log.error("init", "uid start failed: " .. tostring(e))
      trace("uid start failed: " .. tostring(e))
    else
      trace("uid started")
    end
  end

  while true do sched.sleep(60) end
end

return M
