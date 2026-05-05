-- /bin/login.lua — interactive login.
--
-- Reads a username from stdin, then a password (echoed as '*'), looks up
-- /etc/passwd via lib.auth.users, and on success replaces the current
-- shell environment with the user's home/shell + capabilities.
--
-- Used by sessiond on a fresh machine and by `su`. Aborts on three
-- failed attempts with a denial logged to /var/log/audit.log.

local users   = require("lib.auth.users")
local audit   = require("lib.auth.audit")
local console = require("lib.term.console")

local function prompt(text, masked)
  console.write(text)
  if masked then
    -- We can't ask the console editor to mask without a feature flag;
    -- read raw key events ourselves.
    local sched = require("k.sched")
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
  return console.read_line()
end

local args, env = ...
for attempt = 1, 3 do
  local user = prompt("login: ")
  if not user or user == "" then return 1 end
  local pw   = prompt("password: ", true)
  if users.verify(user, pw) then
    local rec = users.get(user)
    env.USER = user
    env.HOME = rec.home
    env.PWD  = rec.home
    audit.write({ kind = "login.ok", user = user })
    print("Welcome, " .. user .. "!")
    return 0
  end
  audit.write({ kind = "login.fail", user = user })
  console.writeln("Login incorrect.")
end
return 1
