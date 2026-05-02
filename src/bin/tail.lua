-- /bin/tail.lua — print the last N lines of input.
local args = ...
local fstream = require("std.fstream")

local n = 10
local files = {}
local i = 1
while i <= #args do
  local a = args[i]
  if a == "-n" then n = tonumber(args[i + 1]) or 10; i = i + 2
  elseif a:match("^%-n%d+$") then n = tonumber(a:sub(3)); i = i + 1
  else files[#files + 1] = a; i = i + 1 end
end

local function tail_stream(stream, count)
  local ring, len, head = {}, 0, 0
  for line in stream:lines("l") do
    head = (head % count) + 1
    ring[head] = line
    if len < count then len = len + 1 end
  end
  local start = (head - len) % count + 1
  for j = 1, len do print(ring[((start - 1 + j - 1) % count) + 1]) end
end

if #files == 0 then tail_stream(io.stdin, n); return 0 end
for _, name in ipairs(files) do
  local s, err = fstream.open(name, "r")
  if not s then io.stderr:write("tail: " .. name .. ": " .. tostring(err) .. "\n"); return 1 end
  tail_stream(s, n); s:close()
end
return 0
