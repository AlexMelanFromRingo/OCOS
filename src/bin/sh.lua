-- /bin/sh.lua — interactive OCOS shell. Reads the user's commands from
-- the current process's stdin (typically the console), parses, and runs.
-- Inherits its own process capabilities so children we spawn (cp, mv,
-- ...) get the same set; without that step the shell strips every cap
-- under cap.is_enforcing() = true, which silently breaks any write.

local sh    = require("lib.sh")
local sched = require("k.sched")

local args, env = ...
local streams = io and { stdin = io.stdin, stdout = io.stdout, stderr = io.stderr }

local function inherited_caps()
  local out = {}
  local me = sched.current()
  if me and me.caps then
    for k in pairs(me.caps) do out[#out + 1] = k end
  end
  return out
end

if args and args[1] == "-c" and args[2] then
  local shell = { env = env or {}, aliases = {}, last_status = 0, caps = inherited_caps() }
  return sh.run_string(args[2], shell, streams)
end

sh.repl({
  env     = env,
  streams = streams,
  caps    = inherited_caps(),
  banner  = (_OSVERSION or "OCOS") .. " — type `help`, `exit` to leave",
})

sched.exit(0)
