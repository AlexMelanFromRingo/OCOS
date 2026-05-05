-- /bin/userdel.lua — remove a user.
local args, env = ...
local users = require("lib.auth.users")
if env.USER ~= "root" then io.stderr:write("userdel: root only\n"); return 1 end
local name = args[1]
if not name then io.stderr:write("usage: userdel <name>\n"); return 2 end
local ok, err = users.remove(name)
if not ok then io.stderr:write("userdel: " .. tostring(err) .. "\n"); return 1 end
print("removed " .. name)
return 0
