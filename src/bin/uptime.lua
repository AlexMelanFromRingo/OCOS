-- /bin/uptime.lua — show how long the system has been up.
local seconds = computer.uptime()
local d = math.floor(seconds / 86400)
local h = math.floor((seconds % 86400) / 3600)
local m = math.floor((seconds % 3600) / 60)
local s = seconds % 60
print(string.format("up %dd %02dh %02dm %05.2fs", d, h, m, s))
return 0
