-- /bin/sleep.lua — pause for the given duration.
--
-- Accepts an unadorned number (seconds) or a number with a unit
-- suffix: `s` (seconds, default), `m` (minutes), `h` (hours),
-- `d` (days). Matches GNU sleep on the suffix subset that scripts
-- actually use; we don't accept multiple operands (GNU sums them)
-- because that's almost always a bug in the caller.

local args = ...
local sched = require("k.sched")

if #args ~= 1 then
  io.stderr:write("usage: sleep N[smhd]\n"); return 2
end

local raw = args[1]
local num, unit = raw:match("^(%d+%.?%d*)([smhd]?)$")
if not num then
  io.stderr:write("sleep: invalid duration: " .. raw .. "\n"); return 2
end
local secs = tonumber(num)
if unit == "m" then secs = secs * 60
elseif unit == "h" then secs = secs * 3600
elseif unit == "d" then secs = secs * 86400 end

sched.sleep(secs)
return 0
