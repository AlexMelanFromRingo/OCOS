-- /bin/cp — copy files and directory trees.
-- Usage: cp [-r] SRC... DST
--   * If DST is a directory, every SRC is copied inside it.
--   * Otherwise exactly one SRC is required and its content is copied to DST.
--   * -r enables directory recursion.

local args, env = ...
local vfs = require("k.vfs")

local function err(msg) io.stderr:write("cp: " .. msg .. "\n") end

local recurse = false
local positional = {}
for i = 1, #args do
  local a = args[i]
  if a == "-r" or a == "-R" or a == "--recursive" then recurse = true
  elseif a == "--" then for j = i + 1, #args do positional[#positional + 1] = args[j] end; break
  elseif a:sub(1, 1) == "-" then err("unknown option: " .. a); return 2
  else positional[#positional + 1] = a end
end

if #positional < 2 then err("missing operand"); return 2 end

local function abs(p)
  if p:sub(1, 1) ~= "/" then p = (env and env.PWD or "/") .. "/" .. p end
  return vfs.canonical(p)
end

local function basename(p) return p:match("([^/]+)$") or p end

local function copy_file(src, dst)
  local data, e = vfs.read_all(src)
  if not data then err("read '" .. src .. "': " .. tostring(e)); return false end
  local ok, we = vfs.write_all(dst, data)
  if not ok then err("write '" .. dst .. "': " .. tostring(we)); return false end
  return true
end

local function copy_tree(src, dst)
  if vfs.isdir(src) then
    if not recurse then err("omitting directory '" .. src .. "'"); return false end
    if vfs.exists(dst) then
      if not vfs.isdir(dst) then
        err("cannot overwrite non-directory '" .. dst .. "' with directory '" .. src .. "'")
        return false
      end
    else
      local ok, e = vfs.mkdir(dst)
      if not ok then err("mkdir '" .. dst .. "': " .. tostring(e)); return false end
    end
    for _, name in ipairs(vfs.list(src) or {}) do
      local clean = name:gsub("/$", "")
      if not copy_tree(src .. "/" .. clean, dst .. "/" .. clean) then return false end
    end
    return true
  end
  return copy_file(src, dst)
end

local dst = abs(positional[#positional])
local sources = {}
for i = 1, #positional - 1 do sources[i] = abs(positional[i]) end

local dst_is_dir = vfs.isdir(dst)
if #sources > 1 and not dst_is_dir then
  err("target '" .. dst .. "' is not a directory"); return 2
end

local rc = 0
for _, src in ipairs(sources) do
  if not vfs.exists(src) then err("'" .. src .. "': No such file"); rc = 1
  else
    local target = dst_is_dir and (dst .. "/" .. basename(src)) or dst
    if not copy_tree(src, target) then rc = 1 end
  end
end
return rc
