-- /bin/sleep.lua — pause for the given number of seconds.
local args = ...
local sched = require("k.sched")
local secs = tonumber(args[1])
if not secs then io.stderr:write("usage: sleep <seconds>\n"); return 2 end
sched.sleep(secs)
return 0
