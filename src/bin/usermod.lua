-- /bin/usermod.lua — modify an existing user's role.
--
-- Usage:
--   usermod --admin <name>      promote: caps = {"*"}
--   usermod --no-admin <name>   demote: reset to default limited caps
--
-- This is the missing piece between useradd (creates) and userdel
-- (removes): once the operator has alex but no admin, they boot into
-- sessiond's rescue-root and run `usermod --admin alex` to grant alex
-- the wildcard cap rather than recreating the account.

local args, env = ...
local users = require("lib.auth.users")

local mode, name
for i = 1, #args do
  local a = args[i]
  if     a == "--admin"    then mode = "admin"
  elseif a == "--no-admin" then mode = "user"
  elseif a:sub(1, 1) == "-" then io.stderr:write("usermod: unknown option: " .. a .. "\n"); return 2
  else name = name or a end
end

if not (mode and name) then
  io.stderr:write("usage: usermod {--admin|--no-admin} <name>\n"); return 2
end
if env.USER ~= "root" and not users.is_admin(env.USER) then
  io.stderr:write("usermod: admin only\n"); return 1
end

local rec = users.get(name)
if not rec then io.stderr:write("usermod: no such user: " .. name .. "\n"); return 1 end

local caps = users.default_caps(name, mode, rec.home)
local ok, err = users.set_caps(name, caps)
if not ok then io.stderr:write("usermod: " .. tostring(err) .. "\n"); return 1 end

print(string.format("user '%s' is now %s", name,
  mode == "admin" and "admin (caps=*)" or "limited"))
return 0
