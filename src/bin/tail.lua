-- /bin/tail.lua — print the last N lines of input.
--
-- Spec parity with GNU tail:
--   tail [-n N] [-q] [-v] [-c BYTES] [--] [FILE...]
--   * `-` as a filename reads stdin.
--   * Legacy `tail -5 FILE` works (any `-<digits>` is interpreted as
--     `-n <digits>`).
--   * Multi-file banner like head.
--   * Files resolved against env.PWD.

local args, env = ...
local vfs     = require("k.vfs")
local fstream = require("std.fstream")
local getopt  = require("lib.getopt")

local SPEC = {
  n = "value", lines   = "n",
  c = "value", bytes   = "c",
  q = "flag",  quiet   = "q", silent = "q",
  v = "flag",  verbose = "v",
  h = "flag",  help    = "h",
}

local normalised = {}
for _, a in ipairs(args) do
  if a:match("^%-%d+$") then
    normalised[#normalised + 1] = "-n"
    normalised[#normalised + 1] = a:sub(2)
  else
    normalised[#normalised + 1] = a
  end
end

local opts, files, err = getopt.parse(normalised, SPEC)
if err then io.stderr:write("tail: " .. err .. "\n"); return 2 end
if opts.h then
  io.write("usage: tail [-n LINES] [-c BYTES] [-q] [-v] [FILE...]\n"); return 0
end

local n_lines = tonumber(opts.n) or 10
local n_bytes = tonumber(opts.c)
local quiet, verbose = opts.q == true, opts.v == true

local function abs(p)
  if p:sub(1, 1) ~= "/" then p = ((env and env.PWD) or "/") .. "/" .. p end
  return vfs.canonical(p)
end

local function tail_lines(stream, count)
  if count <= 0 then return end
  -- Ring buffer keeps the last `count` lines so a 4 MB file with
  -- `-n 10` doesn't blow the heap.
  local ring, len, head = {}, 0, 0
  for line in stream:lines("l") do
    head = (head % count) + 1
    ring[head] = line
    if len < count then len = len + 1 end
  end
  local start_off = head - len
  for j = 1, len do
    local idx = ((start_off + j - 1) % count) + 1
    print(ring[idx])
  end
end

local function tail_bytes(stream, count)
  -- Slurp + slice. For our file sizes (a few MB tops) this is fine.
  local parts = {}
  while true do
    local chunk = stream:read(8192)
    if not chunk or chunk == "" then break end
    parts[#parts + 1] = chunk
  end
  local all = table.concat(parts)
  if count >= #all then io.write(all)
  else io.write(all:sub(-count)) end
end

local function open_one(name)
  if name == "-" then return io.stdin, "-" end
  local path = abs(name)
  local s, oerr = fstream.open(path, "r")
  if not s then return nil, oerr end
  return s, path
end

if #files == 0 then files = { "-" } end
local show_banner = verbose or (#files > 1 and not quiet)

local rc = 0
for idx, name in ipairs(files) do
  local stream, opened = open_one(name)
  if not stream then
    io.stderr:write("tail: " .. name .. ": " .. tostring(opened) .. "\n"); rc = 1
  else
    if show_banner then
      if idx > 1 then io.write("\n") end
      io.write("==> " .. name .. " <==\n")
    end
    if n_bytes then tail_bytes(stream, n_bytes) else tail_lines(stream, n_lines) end
    if stream ~= io.stdin and stream.close then stream:close() end
  end
end
return rc
