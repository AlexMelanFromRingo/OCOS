-- /bin/wc.lua — count lines, words and bytes.
local args = ...
local fstream = require("std.fstream")

local function count_stream(s)
  local lines, words, bytes = 0, 0, 0
  for chunk in function() return s:read(4096) end do
    if not chunk or chunk == "" then break end
    bytes = bytes + #chunk
    for c in chunk:gmatch("\n") do lines = lines + 1; words = words end
    -- count words by splitting on whitespace runs (linewise to avoid memory blow-up)
  end
  return lines, words, bytes
end

local function tally(s)
  local L, W, B = 0, 0, 0
  for line in s:lines("L") do
    L = L + 1
    B = B + #line
    for _ in line:gmatch("%S+") do W = W + 1 end
  end
  return L, W, B
end

if #args == 0 then
  local L, W, B = tally(io.stdin)
  print(string.format("%7d %7d %7d", L, W, B)); return 0
end
local tL, tW, tB = 0, 0, 0
for _, name in ipairs(args) do
  local s, err = fstream.open(name, "r")
  if not s then io.stderr:write("wc: " .. name .. ": " .. tostring(err) .. "\n"); return 1 end
  local L, W, B = tally(s); s:close()
  print(string.format("%7d %7d %7d %s", L, W, B, name))
  tL, tW, tB = tL + L, tW + W, tB + B
end
if #args > 1 then print(string.format("%7d %7d %7d total", tL, tW, tB)) end
return 0
