-- /bin/sudo.lua — run a command with elevated capabilities after re-auth.
--
-- Asks for the current user's password, verifies via PBKDF2, then exec's
-- the requested command with caps={"*"}. The audit log records every
-- attempt and outcome.

local args, env = ...
local users   = require("lib.auth.users")
local audit   = require("lib.auth.audit")
local exec    = require("k.exec")
local sched   = require("k.sched")
local vfs     = require("k.vfs")
local console = require("lib.term.console")

if #args == 0 then io.stderr:write("usage: sudo <cmd> [args...]\n"); return 2 end

local user = env.USER or "root"

local function masked()
  local buf = {}
  while true do
    local ev = sched.wait(function(n) return n == "key_down" end)
    if ev then
      local _, char, code = ev.args[1], ev.args[2], ev.args[3]
      if code == 28 then console.write("\n"); return table.concat(buf) end
      if code == 14 then if #buf > 0 then buf[#buf] = nil end
      elseif char and char >= 32 and char < 127 then
        buf[#buf + 1] = string.char(char); console.write("*")
      end
    end
  end
end

if user ~= "root" or users.get(user) then
  console.write("[sudo] password for " .. user .. ": ")
  local pw = masked()
  if not users.verify(user, pw) then
    audit.write({ kind = "sudo.fail", user = user, action = table.concat(args, " ") })
    io.stderr:write("sudo: authentication failed\n"); return 1
  end
end
audit.write({ kind = "sudo.ok", user = user, action = table.concat(args, " ") })

local cmd = args[1]
local cmd_args = {}
for i = 2, #args do cmd_args[i - 1] = args[i] end

-- Resolve command via PATH, like the shell does.
local function resolve(name)
  if name:find("/", 1, true) then return vfs.exists(name) and name or nil end
  for dir in (env.PATH or "/bin"):gmatch("[^:]+") do
    local p = dir .. "/" .. name .. ".lua"
    if vfs.exists(p) then return p end
    p = dir .. "/" .. name; if vfs.exists(p) then return p end
  end
end

local target = resolve(cmd)
if not target then io.stderr:write("sudo: " .. cmd .. ": not found\n"); return 1 end

local p, err = exec.exec(target, cmd_args, {
  streams   = { stdin = io.stdin, stdout = io.stdout, stderr = io.stderr },
  shell_env = env,
  caps      = { "*" },
  name      = "sudo:" .. cmd,
})
if not p then io.stderr:write("sudo: " .. tostring(err) .. "\n"); return 1 end
local res = sched.wait_pid(p.id)
return (res and res.code) or 0
