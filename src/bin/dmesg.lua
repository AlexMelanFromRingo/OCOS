-- /bin/dmesg.lua
local term = require("lib.term.console")
local log  = require("k.log")

for _, e in ipairs(log.entries()) do
  local stamp = string.format("[%8.3f]", e.time)
  term.writeln(stamp .. " " .. e.level:sub(1, 1):upper() .. " " .. e.tag .. ": " .. e.msg)
end
return 0
