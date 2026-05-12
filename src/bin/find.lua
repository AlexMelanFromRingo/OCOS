-- /bin/find.lua — recursive directory walk with a small predicate set.
--
-- Spec subset: GNU find's predicate syntax is huge; we ship the
-- handful that scripts and interactive use actually need:
--
--   find [PATH...] [-name PAT] [-type f|d] [-maxdepth N]
--
--   * PATH... default to `.` (resolved against env.PWD).
--   * -name PAT: glob-style match against the basename. PAT may use
--     `*` (any chars), `?` (one char), `[abc]` (char class).
--   * -type f / -type d: file / directory only.
--   * -maxdepth N: bound on traversal depth. 0 prints only the roots.
--
-- The predicates are conjunctive — every condition must hold for the
-- path to be printed.

local args, env = ...
local vfs = require("k.vfs")

local roots = {}
local name_pat, type_filter, maxdepth

local i = 1
while i <= #args do
  local a = args[i]
  if a == "-name" then
    name_pat = args[i + 1]; i = i + 2
    if not name_pat then io.stderr:write("find: -name needs a pattern\n"); return 2 end
  elseif a == "-type" then
    type_filter = args[i + 1]; i = i + 2
    if not (type_filter == "f" or type_filter == "d") then
      io.stderr:write("find: -type must be f or d\n"); return 2
    end
  elseif a == "-maxdepth" then
    maxdepth = tonumber(args[i + 1]); i = i + 2
    if not maxdepth then io.stderr:write("find: -maxdepth needs a number\n"); return 2 end
  elseif a == "--" then
    for j = i + 1, #args do roots[#roots + 1] = args[j] end; break
  elseif a:sub(1, 1) == "-" and a ~= "-" then
    io.stderr:write("find: unknown option: " .. a .. "\n"); return 2
  else
    roots[#roots + 1] = a; i = i + 1
  end
end
if #roots == 0 then roots = { "." } end

local function abs(p)
  if p:sub(1, 1) ~= "/" then p = ((env and env.PWD) or "/") .. "/" .. p end
  return vfs.canonical(p)
end

-- Translate a glob into a Lua pattern. * → .*, ? → ., [..] passes
-- through, Lua's pattern specials get escaped.
local function glob_to_pat(g)
  local out = { "^" }
  local idx = 1
  while idx <= #g do
    local c = g:sub(idx, idx)
    if c == "*" then out[#out + 1] = ".*"
    elseif c == "?" then out[#out + 1] = "."
    elseif c == "[" then
      local close = g:find("]", idx + 1, true)
      if not close then out[#out + 1] = "%["
      else out[#out + 1] = g:sub(idx, close); idx = close end
    elseif c:match("[%%%.%-%+%?%(%)%^%$]") then
      out[#out + 1] = "%" .. c
    else
      out[#out + 1] = c
    end
    idx = idx + 1
  end
  out[#out + 1] = "$"
  return table.concat(out)
end

local name_lua_pat = name_pat and glob_to_pat(name_pat)

local function matches(path, isdir)
  if type_filter == "f" and isdir then return false end
  if type_filter == "d" and not isdir then return false end
  if name_lua_pat then
    local base = path:match("([^/]+)$") or path
    if not base:find(name_lua_pat) then return false end
  end
  return true
end

local function walk(root)
  local r = abs(root)
  if not vfs.exists(r) then
    io.stderr:write("find: " .. root .. ": not found\n"); return 1
  end
  -- Stack entries hold {path, depth}.
  local stack = { { r, 0 } }
  while #stack > 0 do
    local top = table.remove(stack)
    local path, depth = top[1], top[2]
    local isdir = vfs.isdir(path)
    if matches(path, isdir) then print(path) end
    if isdir and (not maxdepth or depth < maxdepth) then
      local entries = vfs.list(path) or {}
      for idx = #entries, 1, -1 do
        local name = entries[idx]:gsub("/$", "")
        local sub = (path == "/" and "" or path) .. "/" .. name
        stack[#stack + 1] = { sub, depth + 1 }
      end
    end
  end
  return 0
end

local rc = 0
for _, r in ipairs(roots) do
  local code = walk(r)
  if code ~= 0 then rc = code end
end
return rc
