-- /bin/userdel.lua — remove a user.
--
-- Usage:
--   userdel <name>      remove the entry from /etc/passwd; keep homedir
--   userdel -r <name>   also recursively delete /home/<name>
--
-- We require admin caps (root or any user with caps={"*"}) — limited
-- accounts can't write /etc/passwd anyway with cap.enforce=true, but
-- we check explicitly so the error message is clearer than EPERM.

local args, env = ...
local users = require("lib.auth.users")
local vfs   = require("k.vfs")

local recursive = false
local name
for i = 1, #args do
  local a = args[i]
  if a == "-r" or a == "--remove-home" then recursive = true
  elseif a:sub(1, 1) == "-" then io.stderr:write("userdel: unknown option: " .. a .. "\n"); return 2
  else name = name or a end
end

if not name then io.stderr:write("usage: userdel [-r] <name>\n"); return 2 end
if env.USER ~= "root" and not users.is_admin(env.USER) then
  io.stderr:write("userdel: admin only\n"); return 1
end

local rec = users.get(name)
local home = rec and rec.home or ("/home/" .. name)

local ok, err = users.remove(name)
if not ok then io.stderr:write("userdel: " .. tostring(err) .. "\n"); return 1 end

if recursive and home and vfs.exists(home) then
  -- OC's filesystem.remove already recurses into directories, so one
  -- call is enough — we don't need to walk the tree by hand.
  pcall(vfs.remove, home)
  print(string.format("removed %s and homedir %s", name, home))
elseif home and vfs.exists(home) then
  print(string.format("removed %s (homedir %s left intact — use -r to wipe)", name, home))
else
  print("removed " .. name)
end
return 0
