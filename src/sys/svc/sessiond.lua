-- /sys/svc/sessiond.lua — interactive session manager.
--
-- Owns the console for the duration of the session: prints MOTD, hands a
-- shell its TTY streams, and respawns the shell whenever it exits. When
-- /etc/passwd exists (added in M6 alongside PBKDF2), a login prompt gates
-- the session — until then the only user is `root` and we boot straight
-- into a shell.

local sched   = require("k.sched")
local log     = require("k.log")
local vfs     = require("k.vfs")
local exec    = require("k.exec")
local ipc     = require("k.ipc")
local console = require("lib.term.console")
local tty     = require("lib.term.tty")

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

local STOP = "__sessiond_stop"
local stopping = false
ipc.subscribe("svc.stop.sessiond", function() stopping = true; computer.pushSignal(STOP) end)

console.init()

while not stopping do
  console.set_fg(0xCCCCFF); console.writeln(_OSVERSION)
  console.set_fg(0xCCCCCC)
  local streams = { stdin = tty.stdin(), stdout = tty.stdout(), stderr = tty.stderr() }
  print_motd(streams)
  console.writeln("")

  local sh, err = exec.exec("/bin/sh.lua", {}, {
    streams   = streams,
    shell_env = { PATH = "/bin", PWD = "/", HOME = "/home", USER = "root" },
    caps      = { "*" },
    name      = "sh",
  })
  if not sh then
    streams.stderr:write("sessiond: cannot launch shell: " .. tostring(err) .. "\n")
    log.error("sessiond", "shell launch failed: " .. tostring(err))
    sched.sleep(2)
  else
    sched.wait_pid(sh.id)
    if not stopping then
      console.writeln("[shell exited; restarting]")
      sched.sleep(0.2)
    end
  end
end
return 0
