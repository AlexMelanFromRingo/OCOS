-- /sys/svc/sessiond.lua — interactive session manager.
--
-- Owns the console for the duration of the session. When /etc/passwd has
-- entries, gates the shell with a login prompt and applies the verified
-- user's capabilities; otherwise drops straight into a privileged root
-- shell suitable for first-boot configuration.
--
-- VT switching with the GUI service (uid) goes through ipc:
--   svc.suspend.sessiond   pause the shell child (parked, retains state)
--   svc.resume.sessiond    unpause and trigger a prompt redraw
--
-- The sessiond coroutine itself stays in wait_pid throughout — pausing
-- happens at the proc level so the shell's open file handles, history,
-- env and command line survive the GUI session intact.

local sched   = require("k.sched")
local log     = require("k.log")
local vfs     = require("k.vfs")
local exec    = require("k.exec")
local ipc     = require("k.ipc")
local proc    = require("k.proc")
local console = require("lib.term.console")
local tty     = require("lib.term.tty")
local users   = require("lib.auth.users")
local audit   = require("lib.auth.audit")

-- Append-mode debug trace so we can see what sessiond did across boots
-- when there's no shell to read dmesg from.
local function trace(msg)
  pcall(vfs.mkdir, "/var")
  pcall(vfs.mkdir, "/var/log")
  local h = vfs.open("/var/log/sessiond.trace", "a")
  if not h then return end
  pcall(h.write, h, string.format("[%8.3f] %s\n", computer.uptime(), msg))
  pcall(h.close, h)
end
trace("sessiond up; _OSVERSION=" .. tostring(_OSVERSION))

local function print_motd(streams)
  if not vfs.exists("/etc/motd") then return end
  local h = vfs.open("/etc/motd", "r")
  if not h then return end
  while true do
    local chunk = h:read(4096); if not chunk or chunk == "" then break end
    streams.stdout:write(chunk)
  end
  h:close()
end

local function read_password()
  local buf = {}
  while true do
    local ev = sched.wait(function(name) return name == "key_down" end)
    if ev then
      local _, char, code = ev.args[1], ev.args[2], ev.args[3]
      if code == 28 then console.writeln(""); return table.concat(buf) end
      if code == 14 then if #buf > 0 then buf[#buf] = nil end
      elseif char and char >= 32 and char < 127 then
        buf[#buf + 1] = string.char(char); console.write("*")
      end
    end
  end
end

local function login()
  for _ = 1, 3 do
    console.write("login: ")
    local user = console.read_line()
    if not user or user == "" then return nil end
    console.write("password: ")
    local pw = read_password()
    if users.verify(user, pw) then
      audit.write({ kind = "login.ok", user = user })
      return users.get(user), user
    end
    audit.write({ kind = "login.fail", user = user })
    console.writeln("Login incorrect.")
  end
  return nil
end

local stopping  = false
local active_sh                                    -- pid of the shell we spawned

ipc.subscribe("svc.stop.sessiond", function()
  stopping = true
  if active_sh then pcall(proc.kill, active_sh, "kill") end
  computer.pushSignal("__sessiond_wake")
end)

ipc.subscribe("svc.suspend.sessiond", function()
  if active_sh then pcall(proc.pause, active_sh) end
  ipc.publish("ses.tty.released", {})
end)

ipc.subscribe("svc.resume.sessiond", function()
  if active_sh then pcall(proc.resume, active_sh) end
  ipc.publish("ses.tty.acquired", {})
  -- Ask whatever console.read_line is currently parked in the shell to
  -- repaint its prompt; the GUI cleared the screen on its way out.
  ipc.publish("console.redraw", {})
end)

console.init()
trace("console.init done")

while not stopping do
  trace("loop top")
  console.set_fg(0xCCCCFF); console.writeln(_OSVERSION)
  console.set_fg(0xCCCCCC)
  local streams = { stdin = tty.stdin(), stdout = tty.stdout(), stderr = tty.stderr() }
  print_motd(streams)
  console.writeln("")
  trace("banner painted")

  local rec, name
  if users.empty() then
    rec, name = { home = "/home", caps = { "*" } }, "root"
    trace("users empty, dropping to root")
  else
    rec, name = login()
    if not rec then trace("login failed"); sched.sleep(1); goto continue end
    trace("login ok: " .. name)
  end

  local sh, err = exec.exec("/bin/sh.lua", {}, {
    streams   = streams,
    shell_env = { PATH = "/bin", PWD = rec.home or "/home", HOME = rec.home or "/home", USER = name },
    caps      = rec.caps or {},
    name      = "sh:" .. name,
  })
  if not sh then
    trace("exec.exec FAILED: " .. tostring(err))
    streams.stderr:write("sessiond: cannot launch shell: " .. tostring(err) .. "\n")
    log.error("sessiond", "shell launch failed: " .. tostring(err))
    sched.sleep(2)
  else
    trace("shell pid=" .. sh.id .. ", entering wait_pid")
    active_sh = sh.id
    sched.wait_pid(sh.id)
    active_sh = nil
    trace("shell exited")
    audit.write({ kind = "logout", user = name })
    if not stopping then
      console.writeln("[shell exited]")
      sched.sleep(0.2)
    end
  end
  ::continue::
end
return 0
