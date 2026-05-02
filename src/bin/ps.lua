-- /bin/ps.lua
local term = require("lib.term.console")
local proc = require("k.proc")

term.writeln(string.format("%4s  %-10s  %s", "PID", "STATUS", "NAME"))
for _, p in ipairs(proc.list()) do
  term.writeln(string.format("%4d  %-10s  %s", p.id, p.status, p.name))
end
return 0
