-- /bin/dmesg.lua — print the kernel log ring buffer.
local log = require("k.log")
for _, e in ipairs(log.entries()) do
  print(string.format("[%8.3f] %s %s: %s",
    e.time, e.level:sub(1,1):upper(), e.tag, e.msg))
end
return 0
