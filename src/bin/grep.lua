-- /bin/grep.lua — print lines that match a pattern.
--
-- Spec parity with GNU grep on the flags that scripts actually use:
--   grep [-v] [-i] [-n] [-c] [-l] [-F] [-r] [-H] [--] PATTERN [FILE...]
--   -v   invert match
--   -i   ignore case
--   -n   prefix every matching line with its 1-based line number
--   -c   print only the count of matching lines per file
--   -l   print only names of files that have at least one match
--   -F   literal string match (no pattern characters)
--   -r/-R  recurse into directories
--   -H   force filename prefix even with a single file
--
-- The pattern uses Lua patterns (so `%w` not `\w`, `.` is "any" the
-- same way). With `-F` it's a plain substring. With `-i` both sides
-- are lower-cased before the match.

local args, env = ...
local vfs     = require("k.vfs")
local fstream = require("std.fstream")
local getopt  = require("lib.getopt")

local SPEC = {
  v = "flag",  invert                 = "v", ["invert-match"] = "v",
  i = "flag",  ["ignore-case"]        = "i",
  n = "flag",  ["line-number"]        = "n",
  c = "flag",  count                  = "c",
  l = "flag",  ["files-with-matches"] = "l",
  F = "flag",  ["fixed-strings"]      = "F",
  r = "flag",  R                      = "r", recursive = "r",
  H = "flag",  ["with-filename"]      = "H",
  h = "flag",  help                   = "h",
}

local opts, positional, err = getopt.parse(args, SPEC)
if err then io.stderr:write("grep: " .. err .. "\n"); return 2 end
if opts.h or opts.help then
  io.write("usage: grep [-v] [-i] [-n] [-c] [-l] [-F] [-r] [-H] PATTERN [FILE...]\n"); return 0
end

local pattern = positional[1]
if not pattern then
  io.stderr:write("usage: grep [-v] [-i] [-n] [-c] [-l] [-F] [-r] [-H] PATTERN [FILE...]\n"); return 2
end

local invert  = opts.v == true
local icase   = opts.i == true
local nums    = opts.n == true
local count   = opts.c == true
local fnames  = opts.l == true
local fixed   = opts.F == true
local recurse = opts.r == true
local force_h = opts.H == true

if icase then pattern = pattern:lower() end

local function match(line)
  local subject = icase and line:lower() or line
  if fixed then return subject:find(pattern, 1, true) ~= nil end
  return subject:find(pattern) ~= nil
end

local function abs(p)
  if p:sub(1, 1) ~= "/" then p = ((env and env.PWD) or "/") .. "/" .. p end
  return vfs.canonical(p)
end

local function collect_files(root_args)
  local out = {}
  for _, name in ipairs(root_args) do
    local p = abs(name)
    if vfs.isdir(p) then
      if not recurse then
        io.stderr:write("grep: " .. name .. ": is a directory (use -r)\n")
      else
        local stack = { p }
        while #stack > 0 do
          local cur = table.remove(stack)
          for _, e in ipairs(vfs.list(cur) or {}) do
            local child = (cur == "/" and "" or cur) .. "/" .. e:gsub("/$", "")
            if vfs.isdir(child) then stack[#stack + 1] = child
            else out[#out + 1] = child end
          end
        end
      end
    else
      out[#out + 1] = p
    end
  end
  return out
end

local function scan(stream, label)
  local matches, lineno = 0, 0
  for line in stream:lines("l") do
    lineno = lineno + 1
    local hit = match(line)
    if hit ~= invert then
      matches = matches + 1
      if not count and not fnames then
        local parts = {}
        if label then parts[#parts + 1] = label end
        if nums then parts[#parts + 1] = tostring(lineno) end
        parts[#parts + 1] = line
        print(table.concat(parts, ":"))
      elseif fnames then
        return matches, true                           -- short-circuit
      end
    end
  end
  return matches, false
end

local input_files = {}
for j = 2, #positional do input_files[#input_files + 1] = positional[j] end

if #input_files == 0 then
  local m = scan(io.stdin, nil)
  if count then print(m) end
  return (m > 0) and 0 or 1
end

local resolved = collect_files(input_files)
local show_label = force_h or recurse or #resolved > 1
local any_match = false

for _, path in ipairs(resolved) do
  local s, oerr = fstream.open(path, "r")
  if not s then
    io.stderr:write("grep: " .. path .. ": " .. tostring(oerr) .. "\n")
  else
    local label = show_label and path or nil
    local m = scan(s, fnames and nil or label)
    s:close()
    if m > 0 then any_match = true end
    if count then
      if show_label then print(path .. ":" .. m) else print(m) end
    elseif fnames and m > 0 then
      print(path)
    end
  end
end

return any_match and 0 or 1
