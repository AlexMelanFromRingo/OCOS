-- /bin/wc.lua — count lines, words and bytes.
--
-- Spec parity with GNU wc:
--   wc [-l] [-w] [-c] [-m] [--] [FILE...]
--   With no selector flag, prints all three counts (lines / words /
--   bytes). With selectors, only the requested columns are printed.
--   `-` or no file at all reads stdin. Files are resolved against
--   env.PWD. With multiple files, a `total` row is added.

local args, env = ...
local vfs     = require("k.vfs")
local fstream = require("std.fstream")
local getopt  = require("lib.getopt")

local SPEC = {
  l = "flag", lines = "l",
  w = "flag", words = "w",
  c = "flag", bytes = "c",
  m = "flag", chars = "m",
  h = "flag", help  = "h",
}

local opts, files, err = getopt.parse(args, SPEC)
if err then io.stderr:write("wc: " .. err .. "\n"); return 2 end
if opts.h then
  io.write("usage: wc [-l] [-w] [-c] [-m] [FILE...]\n"); return 0
end

local want_l = opts.l == true
local want_w = opts.w == true
local want_c = opts.c == true or opts.m == true
-- Default behaviour: when no selectors, show all three.
if not (want_l or want_w or want_c) then want_l, want_w, want_c = true, true, true end

local function tally(s)
  local L, W, B = 0, 0, 0
  for line in s:lines("L") do
    L = L + 1
    B = B + #line
    for _ in line:gmatch("%S+") do W = W + 1 end
  end
  return L, W, B
end

local function fmt(L, W, B, label)
  local parts = {}
  if want_l then parts[#parts + 1] = string.format("%7d", L) end
  if want_w then parts[#parts + 1] = string.format("%7d", W) end
  if want_c then parts[#parts + 1] = string.format("%7d", B) end
  if label  then parts[#parts + 1] = label end
  return table.concat(parts, " ")
end

local function abs(p)
  if p:sub(1, 1) ~= "/" then p = ((env and env.PWD) or "/") .. "/" .. p end
  return vfs.canonical(p)
end

if #files == 0 or (#files == 1 and files[1] == "-") then
  print(fmt(tally(io.stdin))); return 0
end

local tL, tW, tB = 0, 0, 0
local rc = 0
for _, name in ipairs(files) do
  local s, oerr
  if name == "-" then s = io.stdin
  else s, oerr = fstream.open(abs(name), "r") end
  if not s then
    io.stderr:write("wc: " .. name .. ": " .. tostring(oerr) .. "\n"); rc = 1
  else
    local L, W, B = tally(s)
    if s ~= io.stdin then s:close() end
    print(fmt(L, W, B, name))
    tL, tW, tB = tL + L, tW + W, tB + B
  end
end
if #files > 1 then print(fmt(tL, tW, tB, "total")) end
return rc
