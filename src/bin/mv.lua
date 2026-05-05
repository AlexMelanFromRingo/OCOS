-- /bin/mv — move/rename files and directories.
-- Usage: mv SRC... DST
--   * Same single-/multi-source rules as cp.
--   * Tries vfs.rename first; on cross-device failure, falls back to a
--     full copy + remove.

local args, env = ...
local vfs = require("k.vfs")

local function err(msg) io.stderr:write("mv: " .. msg .. "\n") end

local positional = {}
for i = 1, #args do
  local a = args[i]
  if a == "--" then for j = i + 1, #args do positional[#positional + 1] = args[j] end; break
  elseif a:sub(1, 1) == "-" then err("unknown option: " .. a); return 2
  else positional[#positional + 1] = a end
end
if #positional < 2 then err("missing operand"); return 2 end

local function abs(p)
  if p:sub(1, 1) ~= "/" then p = (env and env.PWD or "/") .. "/" .. p end
  return vfs.canonical(p)
end
local function basename(p) return p:match("([^/]+)$") or p end

local function copy_tree(src, dst)
  if vfs.isdir(src) then
    if not vfs.exists(dst) then
      local ok, e = vfs.mkdir(dst)
      if not ok then err("mkdir '" .. dst .. "': " .. tostring(e)); return false end
    elseif not vfs.isdir(dst) then
      err("'" .. dst .. "' exists and is not a directory"); return false
    end
    for _, name in ipairs(vfs.list(src) or {}) do
      local clean = name:gsub("/$", "")
      if not copy_tree(src .. "/" .. clean, dst .. "/" .. clean) then return false end
    end
    return true
  end
  local data, e = vfs.read_all(src); if not data then err("read '" .. src .. "': " .. tostring(e)); return false end
  local ok, we = vfs.write_all(dst, data); if not ok then err("write '" .. dst .. "': " .. tostring(we)); return false end
  return true
end

local function rm_tree(path)
  if vfs.isdir(path) then
    for _, name in ipairs(vfs.list(path) or {}) do
      local clean = name:gsub("/$", "")
      if not rm_tree(path .. "/" .. clean) then return false end
    end
  end
  local ok, e = vfs.remove(path); if not ok then err("cleanup '" .. path .. "': " .. tostring(e)); return false end
  return true
end

local function move_one(src, dst)
  if not vfs.exists(src) then err("'" .. src .. "': No such file"); return false end
  if vfs.exists(dst) and vfs.canonical(src) == vfs.canonical(dst) then
    err("'" .. src .. "' and '" .. dst .. "' are the same file"); return false
  end
  local ok = vfs.rename(src, dst)
  if ok then return true end
  if not copy_tree(src, dst) then return false end
  return rm_tree(src)
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
  local target = dst_is_dir and (dst .. "/" .. basename(src)) or dst
  if not move_one(src, target) then rc = 1 end
end
return rc
