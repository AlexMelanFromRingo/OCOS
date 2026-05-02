-- /bin/sh.lua — interactive OCOS shell. Reads the user's commands from
-- the current process's stdin (typically the console), parses, and runs.

local sh   = require("lib.sh")
local sched = require("k.sched")

local args, env = ...
local streams = io and { stdin = io.stdin, stdout = io.stdout, stderr = io.stderr }

if args and args[1] == "-c" and args[2] then
  -- Non-interactive single command, primarily for tests and scripts.
  local shell = { env = env or {}, aliases = {}, last_status = 0 }
  return sh.run_string(args[2], shell, streams)
end

sh.repl({
  env     = env,
  streams = streams,
  banner  = (_OSVERSION or "OCOS") .. " — type `help`, `exit` to leave",
})

sched.exit(0)
