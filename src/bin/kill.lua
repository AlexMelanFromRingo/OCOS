-- /bin/kill — send a termination signal to a process by pid.
-- Usage: kill [-9 | -KILL | -TERM] PID...
--   * Default sends SIGTERM (cooperative); the target gets an ipc
--     `proc.term` event and can shut down cleanly.
--   * -9 sends SIGKILL (hard dispose).

local args, _ = ...
local proc  = require("k.proc")
local cap   = require("k.cap")
local sched = require("k.sched")

local function err(msg) io.stderr:write("kill: " .. msg .. "\n") end

local sig = "term"
local pids = {}
for i = 1, #args do
  local a = args[i]
  if a == "-9" or a == "-KILL" or a == "-SIGKILL" then sig = "kill"
  elseif a == "-15" or a == "-TERM" or a == "-SIGTERM" then sig = "term"
  elseif a == "--" then for j = i + 1, #args do pids[#pids + 1] = args[j] end; break
  elseif a:sub(1, 1) == "-" and #a > 1 then err("unknown option: " .. a); return 2
  else pids[#pids + 1] = a end
end
if #pids == 0 then err("usage: kill [-9] PID..."); return 2 end

local me = sched.current()
local cap_name = sig == "kill" and "syscall:kill:9" or "syscall:kill"
if not cap.check(me and me.caps, cap_name, { user = me and me.shell_env and me.shell_env.USER }) then
  err("permission denied: " .. cap_name); return 1
end

local rc = 0
for _, raw in ipairs(pids) do
  local pid = tonumber(raw)
  if not pid then err("not a pid: " .. raw); rc = 1
  else
    local ok, e = proc.kill(pid, sig)
    if not ok then err(raw .. ": " .. tostring(e)); rc = 1 end
  end
end
return rc
