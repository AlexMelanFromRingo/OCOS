-- /bin/mounts.lua — print the VFS mount table.
local vfs = require("k.vfs")
for _, m in ipairs(vfs.mounts()) do
  print(string.format("%-20s %s", m.prefix, m.address:sub(1, 8)))
end
return 0
