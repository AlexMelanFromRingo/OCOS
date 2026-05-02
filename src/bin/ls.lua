-- /bin/ls.lua
local args, env = ...
local term = require("lib.term.console")
local vfs  = require("k.vfs")

local path = args[1] or env.PWD or "/"
if path:sub(1, 1) ~= "/" then path = vfs.canonical((env.PWD or "/") .. "/" .. path) end

if not vfs.exists(path) then term.writeln("ls: not found: " .. path); return 1 end
if not vfs.isdir(path) then term.writeln(path); return 0 end

local entries, err = vfs.list(path)
if not entries then term.writeln("ls: " .. tostring(err)); return 1 end

table.sort(entries)
for _, name in ipairs(entries) do
  local full = path == "/" and "/" .. name or path .. "/" .. name
  local marker = vfs.isdir(full) and "/" or ""
  term.writeln(name .. marker)
end
return 0
