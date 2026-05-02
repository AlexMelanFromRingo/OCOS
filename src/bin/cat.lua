-- /bin/cat.lua
local args, env = ...
local term = require("lib.term.console")
local vfs  = require("k.vfs")

if not args[1] then term.writeln("usage: cat <path>"); return 2 end
local path = args[1]
if path:sub(1, 1) ~= "/" then path = vfs.canonical((env.PWD or "/") .. "/" .. path) end

local h, err = vfs.open(path, "r")
if not h then term.writeln("cat: " .. tostring(err)); return 1 end
while true do
  local chunk = h:read(1024)
  if not chunk then break end
  term.write(chunk)
end
h:close()
term.write("\n")
return 0
