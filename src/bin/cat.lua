-- /bin/cat.lua — concatenate files (or stdin) to stdout.
local args, env = ...
local vfs = require("k.vfs")

local function dump_stream(stream)
  while true do
    local chunk = stream:read(4096)
    if not chunk or chunk == "" then break end
    io.write(chunk)
  end
end

if #args == 0 then
  dump_stream(io.stdin); return 0
end

for _, name in ipairs(args) do
  local path = name:sub(1, 1) == "/" and name or vfs.canonical((env.PWD or "/") .. "/" .. name)
  local h, err = vfs.open(path, "r")
  if not h then
    io.stderr:write("cat: " .. name .. ": " .. tostring(err) .. "\n")
    return 1
  end
  while true do
    local chunk = h:read(4096)
    if not chunk or chunk == "" then break end
    io.write(chunk)
  end
  h:close()
end
return 0
