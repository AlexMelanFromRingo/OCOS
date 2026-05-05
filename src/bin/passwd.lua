-- /bin/passwd.lua — change a user's password.
local args, env = ...
local users   = require("lib.auth.users")
local console = require("lib.term.console")
local sched   = require("k.sched")

local function masked()
  local buf = {}
  while true do
    local ev = sched.wait(function(name) return name == "key_down" end)
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

local target = args[1] or env.USER
if not target then io.stderr:write("usage: passwd [user]\n"); return 2 end
if not users.get(target) then
  io.stderr:write("passwd: no such user: " .. target .. "\n"); return 1
end

if env.USER ~= target and env.USER ~= "root" then
  io.stderr:write("passwd: only root can change other users' passwords\n"); return 1
end

if env.USER == target then
  console.write("current password: ")
  local cur = masked()
  if not users.verify(target, cur) then
    io.stderr:write("passwd: authentication failed\n"); return 1
  end
end

console.write("new password: ");        local p1 = masked()
console.write("retype new password: "); local p2 = masked()
if p1 ~= p2 then io.stderr:write("passwd: passwords don't match\n"); return 1 end
local ok, err = users.set_password(target, p1)
if not ok then io.stderr:write("passwd: " .. tostring(err) .. "\n"); return 1 end
print("password updated for " .. target)
return 0
