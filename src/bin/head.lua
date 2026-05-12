-- /bin/head.lua — print the first N lines of input.
--
-- Spec parity with GNU head:
--   head [-n N] [-q] [-v] [-c BYTES] [--] [FILE...]
--   * `-` as a filename reads stdin.
--   * Legacy `head -5 FILE` works (any `-<digits>` is interpreted as
--     `-n <digits>`).
--   * `-n N` accepts negative N (print all but last N lines); we do
--     the common positive case here.
--   * With more than one file, a `==> NAME <==` banner is printed
--     between files unless `-q` is given. `-v` forces it for one file.
--   * Files are opened relative to env.PWD (matches every other /bin
--     tool that takes a path).

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

-- GNU head allows `head -5 file` as a synonym for `-n 5`. Translate
-- those tokens into the long form before handing to getopt.
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
if err then io.stderr:write("head: " .. err .. "\n"); return 2 end
if opts.h then
  io.write("usage: head [-n LINES] [-c BYTES] [-q] [-v] [FILE...]\n"); return 0
end

local n_lines = tonumber(opts.n) or 10
local n_bytes = tonumber(opts.c)        -- optional; preempts line mode
local quiet, verbose = opts.q == true, opts.v == true

local function abs(p)
  if p:sub(1, 1) ~= "/" then p = ((env and env.PWD) or "/") .. "/" .. p end
  return vfs.canonical(p)
end

local function head_lines(stream, count)
  for line in stream:lines("l") do
    if count <= 0 then return end
    print(line); count = count - 1
  end
end

local function head_bytes(stream, count)
  while count > 0 do
    local chunk = stream:read(math.min(4096, count))
    if not chunk or chunk == "" then return end
    io.write(chunk)
    count = count - #chunk
  end
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
    io.stderr:write("head: " .. name .. ": " .. tostring(opened) .. "\n"); rc = 1
  else
    if show_banner then
      if idx > 1 then io.write("\n") end
      io.write("==> " .. name .. " <==\n")
    end
    if n_bytes then head_bytes(stream, n_bytes) else head_lines(stream, n_lines) end
    if stream ~= io.stdin and stream.close then stream:close() end
  end
end
return rc
