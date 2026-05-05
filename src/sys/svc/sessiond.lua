-- /sys/svc/sessiond.lua — interactive session manager.
--
-- Owns the console for the duration of the session. When /etc/passwd has
-- entries, gates the shell with a login prompt and applies the verified
-- user's capabilities; otherwise drops straight into a privileged root
-- shell suitable for first-boot configuration.

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
  for attempt = 1, 3 do
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

local stopping = false
ipc.subscribe("svc.stop.sessiond", function()
  stopping = true; computer.pushSignal("__sessiond_stop")
end)

-- Diagnostic trace: appended to /var/log/sessiond.trace on the boot fs at
-- every step of the loop. If the user reports a black-screen-after-motd
-- problem, this file pins down which step failed without needing to
-- instrument the screen output.
local function trace(msg)
  local boot = component.proxy(_OCOS.boot_addr)
  if not boot or (boot.isReadOnly and boot.isReadOnly()) then return end
  pcall(vfs.mkdir, "/var")
  pcall(vfs.mkdir, "/var/log")
  local h = vfs.open("/var/log/sessiond.trace", "a")
  if not h then return end
  h:write(string.format("[%8.3f] %s\n", computer.uptime(), msg))
  h:close()
end

console.init()
trace("sessiond up; console initialised")

while not stopping do
  trace("loop top")
  console.set_fg(0xCCCCFF); console.writeln(_OSVERSION)
  console.set_fg(0xCCCCCC)
  local streams = { stdin = tty.stdin(), stdout = tty.stdout(), stderr = tty.stderr() }
  print_motd(streams)
  console.writeln("")
  trace("motd printed")

  -- Heavily-instrumented users-check: pinpoints whether the hang is in
  -- the require chain, the filesystem walk, or somewhere else entirely.
  trace("calling users.empty")
  local empty_ok, empty_v = pcall(users.empty)
  trace("users.empty returned: ok=" .. tostring(empty_ok) .. " v=" .. tostring(empty_v))

  local rec, name
  if not empty_ok then
    trace("users.empty errored: " .. tostring(empty_v) .. " — falling back to root")
    rec, name = { home = "/home", caps = { "*" } }, "root"
  elseif empty_v then
    rec, name = { home = "/home", caps = { "*" } }, "root"
    trace("users empty -> root mode")
  else
    rec, name = login()
    if not rec then trace("login failed"); sched.sleep(1); goto continue end
    trace("login ok: " .. name)
  end

  trace("about to exec.exec /bin/sh.lua")
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
    trace("exec.exec ok pid=" .. sh.id .. "; entering wait_pid")
    local res = sched.wait_pid(sh.id)
    trace("wait_pid returned: code=" .. tostring(res and res.code) ..
          " reason=" .. tostring(res and res.reason))
    audit.write({ kind = "logout", user = name })
    if not stopping then
      console.writeln("[shell exited]")
      sched.sleep(0.2)
    end
  end
  ::continue::
end
return 0
