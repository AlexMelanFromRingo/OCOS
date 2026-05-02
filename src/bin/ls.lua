-- /bin/ls.lua — list directory contents.
local args, env = ...
local vfs = require("k.vfs")

local path = args[1] or env.PWD or "/"
if path:sub(1, 1) ~= "/" then path = vfs.canonical((env.PWD or "/") .. "/" .. path) end

if not vfs.exists(path) then
  io.stderr:write("ls: not found: " .. path .. "\n"); return 1
end
if not vfs.isdir(path) then print(path); return 0 end

local entries, err = vfs.list(path)
if not entries then io.stderr:write("ls: " .. tostring(err) .. "\n"); return 1 end

table.sort(entries)
for _, name in ipairs(entries) do
  local full = path == "/" and "/" .. name or path .. "/" .. name
  print(name .. (vfs.isdir(full) and "/" or ""))
end
return 0
