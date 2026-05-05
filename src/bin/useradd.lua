-- /bin/useradd.lua — create a new user.
local args, env = ...
local users   = require("lib.auth.users")
local console = require("lib.term.console")
local sched   = require("k.sched")

local name = args[1]
if not name then io.stderr:write("usage: useradd <name>\n"); return 2 end
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

local ok, err = users.create(name, p1, {})
if not ok then io.stderr:write("useradd: " .. tostring(err) .. "\n"); return 1 end
print("user '" .. name .. "' created")
return 0
