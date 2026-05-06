-- /bin/setup-root.lua — one-shot install-time admin setup.
--
-- After a fresh install /etc/passwd is empty; sessiond drops straight
-- to root with no password and the kernel runs with enforce=false.
-- This script asks the operator for a root password, creates a real
-- root account in /etc/passwd, then flips /etc/security.cfg so cap
-- enforcement is on. From that moment forward only an admin (root or
-- a user explicitly granted caps={"*"}) can write /etc/passwd, and
-- non-admin processes can't tamper with /etc at all.
--
-- Run once at install time. Re-running will refuse if root already
-- exists (use `passwd root` to change the password, or
-- `usermod --admin <name>` to mint additional admins).

local args, env = ...
local users   = require("lib.auth.users")
local console = require("lib.term.console")
local sched   = require("k.sched")
local vfs     = require("k.vfs")

if env.USER ~= "root" and not users.is_admin(env.USER) then
  io.stderr:write("setup-root: must run as root or another admin\n")
  return 1
end

if users.get("root") then
  io.stderr:write("setup-root: root already exists in /etc/passwd\n")
  io.stderr:write("            use `passwd root` to change the password\n")
  return 1
end

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

console.writeln("OCOS root setup")
console.writeln("---------------")
console.writeln("Pick a password. After this is done /etc/security.cfg")
console.writeln("flips to enforce=true and only admins can create users.")
console.writeln("")
console.write("root password: "); local p1 = masked()
console.write("retype:        "); local p2 = masked()
if p1 ~= p2 then io.stderr:write("setup-root: passwords don't match\n"); return 1 end
if #p1 < 6 then io.stderr:write("setup-root: password too short (need >= 6 chars)\n"); return 1 end

local ok, err = users.create("root", p1, { role = "admin", uid = 0, home = "/root" })
if not ok then io.stderr:write("setup-root: " .. tostring(err) .. "\n"); return 1 end

-- Flip security.cfg to enforce mode. We rewrite the whole file so any
-- previous comment block is replaced — the operator can re-edit later
-- if they want a different policy.
local sec = "-- /etc/security.cfg — kernel security policy.\n"
        .. "-- Set up by /bin/setup-root. Edit if you need to switch back\n"
        .. "-- (enforce=false) for a recovery boot.\n"
        .. "return {\n"
        .. "  enforce = true,\n"
        .. "  default_user = \"root\",\n"
        .. "}\n"
local sok, serr = vfs.write_all("/etc/security.cfg", sec)
if not sok then
  io.stderr:write("setup-root: wrote /etc/passwd but failed to flip security.cfg: "
    .. tostring(serr) .. "\n")
  return 1
end

console.writeln("")
console.writeln("root created with admin caps. Reboot for enforcement to apply.")
console.writeln("Use `useradd <name>` for everyday accounts; only admins (root,")
console.writeln("or `usermod --admin <name>`) can create more admins.")
return 0
