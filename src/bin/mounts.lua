-- /bin/mounts.lua
local term = require("lib.term.console")
local vfs  = require("k.vfs")

for _, m in ipairs(vfs.mounts()) do
  term.writeln(string.format("%-20s %s", m.prefix, m.address:sub(1, 8)))
end
return 0
