-- /sys/svc/sessiond.lua — interactive session manager.
--
-- Owns the console for the duration of the session. When /etc/passwd has
-- entries, gates the shell with a login prompt and applies the verified
-- user's capabilities; otherwise drops straight into a privileged root
-- shell suitable for first-boot configuration.
--
-- Cooperates with the GUI session manager (uid) through ipc:
--   * publishes  ses.tty.released   when suspending (uid is taking over)
--   * publishes  ses.tty.acquired   when resuming
--   * subscribes svc.suspend.sessiond / svc.resume.sessiond
--   * subscribes svc.stop.sessiond  (cooperative shutdown)

local sched   = require("k.sched")
local log     = require("k.log")
local vfs     = require("k.vfs")
local exec    = require("k.exec")
local ipc     = require("k.ipc")
local console = require("lib.term.console")
local tty     = require("lib.term.tty")
local users   = require("lib.auth.users")
local audit   = require("lib.auth.audit")

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

-- Read a password from the keyboard without echoing the characters.
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
local suspended = false
local active_sh                                    -- pid of the shell we spawned

local function tear_down_shell()
  if active_sh then
    local proc = require("k.proc")
    pcall(proc.kill, active_sh, "kill")
    active_sh = nil
  end
end

ipc.subscribe("svc.stop.sessiond", function()
  stopping = true; tear_down_shell(); computer.pushSignal("__sessiond_wake")
end)
ipc.subscribe("svc.suspend.sessiond", function()
  suspended = true; tear_down_shell(); computer.pushSignal("__sessiond_wake")
end)
ipc.subscribe("svc.resume.sessiond", function()
  suspended = false; computer.pushSignal("__sessiond_wake")
end)

console.init()

while not stopping do
  if suspended then
    ipc.publish("ses.tty.released", {})
    while suspended and not stopping do
      sched.wait(function(name) return name == "__sessiond_wake" end, 1)
    end
    if stopping then break end
    console.init()
    ipc.publish("ses.tty.acquired", {})
  end

  console.set_fg(0xCCCCFF); console.writeln(_OSVERSION)
  console.set_fg(0xCCCCCC)
  local streams = { stdin = tty.stdin(), stdout = tty.stdout(), stderr = tty.stderr() }
  print_motd(streams)
  console.writeln("")

  local rec, name
  if users.empty() then
    rec, name = { home = "/home", caps = { "*" } }, "root"
  else
    rec, name = login()
    if not rec then sched.sleep(1); goto continue end
  end

  local sh, err = exec.exec("/bin/sh.lua", {}, {
    streams   = streams,
    shell_env = { PATH = "/bin", PWD = rec.home or "/home", HOME = rec.home or "/home", USER = name },
    caps      = rec.caps or {},
    name      = "sh:" .. name,
  })
  if not sh then
    streams.stderr:write("sessiond: cannot launch shell: " .. tostring(err) .. "\n")
    log.error("sessiond", "shell launch failed: " .. tostring(err))
    sched.sleep(2)
  else
    active_sh = sh.id
    sched.wait_pid(sh.id)
    active_sh = nil
    audit.write({ kind = "logout", user = name })
    if not stopping and not suspended then
      console.writeln("[shell exited]")
      sched.sleep(0.2)
    end
  end
  ::continue::
end
return 0
