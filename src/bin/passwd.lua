-- /bin/passwd.lua — change a user's password.
local args, env = ...
local users   = require("lib.auth.users")
local console = require("lib.term.console")

local target = args[1] or env.USER
if not target then io.stderr:write("usage: passwd [user]\n"); return 2 end
if not users.get(target) then
  io.stderr:write("passwd: no such user: " .. target .. "\n"); return 1
end

if env.USER ~= target and env.USER ~= "root" then
  io.stderr:write("passwd: only root can change other users' passwords\n"); return 1
end

if env.USER == target then
  local cur = console.read_password("current password: ")
  if not users.verify(target, cur) then
    io.stderr:write("passwd: authentication failed\n"); return 1
  end
end

local p1 = console.read_password("new password: ")
local p2 = console.read_password("retype new password: ")
if p1 ~= p2 then io.stderr:write("passwd: passwords don't match\n"); return 1 end
local ok, err = users.set_password(target, p1)
if not ok then io.stderr:write("passwd: " .. tostring(err) .. "\n"); return 1 end
print("password updated for " .. target)
return 0
