-- /bin/head.lua — print the first N lines of input.
local args = ...
local vfs = require("k.vfs")

local n = 10
local files = {}
local i = 1
while i <= #args do
  local a = args[i]
  if a == "-n" then n = tonumber(args[i + 1]) or 10; i = i + 2
  elseif a:match("^%-n%d+$") then n = tonumber(a:sub(3)); i = i + 1
  else files[#files + 1] = a; i = i + 1 end
end

local function head_stream(stream, count)
  for line in stream:lines("l") do
    if count <= 0 then return end
    print(line); count = count - 1
  end
end

if #files == 0 then head_stream(io.stdin, n); return 0 end
for _, name in ipairs(files) do
  local h, err = vfs.open(name, "r")
  if not h then io.stderr:write("head: " .. name .. ": " .. tostring(err) .. "\n"); return 1 end
  local stream = require("std.fstream").open(name, "r") or h
  head_stream(stream, n)
  if stream.close then stream:close() end
end
return 0
