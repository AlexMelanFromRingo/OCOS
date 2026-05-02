-- /bin/ps.lua — list current processes.
local proc = require("k.proc")
print(string.format("%4s  %-10s  %s", "PID", "STATUS", "NAME"))
for _, p in ipairs(proc.list()) do
  print(string.format("%4d  %-10s  %s", p.id, p.status, p.cmdline or p.name))
end
return 0
