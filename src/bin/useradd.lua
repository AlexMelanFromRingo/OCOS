-- /bin/useradd.lua — create a new user.
-- Usage: useradd [--admin] <name>
--   --admin   grant the new user caps={"*"} (full privileges; can sudo).
--             Without it, the user gets a sane limited set: exec, write
--             to /home/<name> + /tmp, all hardware components, IPC.

local args, env = ...
local users   = require("lib.auth.users")
local console = require("lib.term.console")
local sched   = require("k.sched")

local role = "user"
local name
for i = 1, #args do
  local a = args[i]
  if a == "--admin" then role = "admin"
  elseif a:sub(1, 1) == "-" then io.stderr:write("useradd: unknown option: " .. a .. "\n"); return 2
  else name = name or a end
end

if not name then io.stderr:write("usage: useradd [--admin] <name>\n"); return 2 end
if users.get(name) then io.stderr:write("user exists\n"); return 1 end

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

console.write("password: "); local p1 = masked()
console.write("retype:   "); local p2 = masked()
if p1 ~= p2 then io.stderr:write("passwords don't match\n"); return 1 end
if #p1 < 4 then io.stderr:write("password too short (need >= 4 chars)\n"); return 1 end

local ok, err = users.create(name, p1, { role = role })
if not ok then io.stderr:write("useradd: " .. tostring(err) .. "\n"); return 1 end
print(string.format("user '%s' created (%s)", name,
  role == "admin" and "full privileges — can sudo" or "limited; sudo will refuse"))
-- Heads-up: a /etc/passwd with no admin entry locks the operator out
-- of admin tasks (a non-admin alex can't even create another user).
-- sessiond's rescue path catches this on next boot, but the user
-- should know now so they can run `useradd --admin <name>` proactively.
if not users.has_admin() then
  io.stderr:write("useradd: warning — no admin user exists. ")
  io.stderr:write("On next boot the system will rescue you back to root.\n")
  io.stderr:write("           To fix now: useradd --admin <name>\n")
end
return 0
