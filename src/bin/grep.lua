-- /bin/grep.lua — print lines that match a Lua pattern.
local args = ...
local fstream = require("std.fstream")

local invert, fixed = false, false
local files = {}
local pattern
local i = 1
while i <= #args do
  local a = args[i]
  if     a == "-v" then invert = true; i = i + 1
  elseif a == "-F" then fixed  = true; i = i + 1
  elseif not pattern then pattern = a; i = i + 1
  else files[#files + 1] = a; i = i + 1 end
end
if not pattern then
  io.stderr:write("usage: grep [-v] [-F] <pattern> [file...]\n"); return 2
end

local function match(line)
  if fixed then return line:find(pattern, 1, true) ~= nil end
  return line:find(pattern) ~= nil
end

local function scan(stream, prefix)
  for line in stream:lines("l") do
    if match(line) ~= invert then
      if prefix then print(prefix .. ":" .. line) else print(line) end
    end
  end
end

if #files == 0 then scan(io.stdin); return 0 end
local show_prefix = #files > 1
for _, name in ipairs(files) do
  local s, err = fstream.open(name, "r")
  if not s then io.stderr:write("grep: " .. name .. ": " .. tostring(err) .. "\n"); return 1 end
  scan(s, show_prefix and name or nil); s:close()
end
return 0
