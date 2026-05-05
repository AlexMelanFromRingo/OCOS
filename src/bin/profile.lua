-- /bin/profile.lua — wall-time benchmark of a script.
local args, env = ...
local prof  = require("lib.devtools.profile")
local exec  = require("k.exec")
local sched = require("k.sched")
local vfs   = require("k.vfs")

if not args[1] then io.stderr:write("usage: profile <script> [args...]\n"); return 2 end

local target = args[1]
if target:sub(1, 1) ~= "/" then
  for dir in (env.PATH or "/bin"):gmatch("[^:]+") do
    if vfs.exists(dir .. "/" .. target .. ".lua") then
      target = dir .. "/" .. target .. ".lua"; break
    end
  end
end
if not vfs.exists(target) then
  io.stderr:write("profile: not found: " .. target .. "\n"); return 1
end

local cmd_args = {}
for i = 2, #args do cmd_args[i - 1] = args[i] end

local before = computer.uptime()
local p, err = exec.exec(target, cmd_args, {
  streams   = { stdin = io.stdin, stdout = io.stdout, stderr = io.stderr },
  shell_env = env, caps = { "*" }, name = "profile:" .. target,
})
if not p then io.stderr:write("profile: " .. tostring(err) .. "\n"); return 1 end
local res = sched.wait_pid(p.id)
local elapsed = computer.uptime() - before

io.stderr:write(string.format(
  "\nprofile: %s exited %d in %.3f s\n", target, res and res.code or -1, elapsed))
return 0
