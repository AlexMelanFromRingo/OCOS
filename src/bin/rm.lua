-- /bin/rm — remove files and directories.
-- Usage: rm [-r] [-f] PATH...
--   -r   recurse into directories.
--   -f   ignore missing operands; never prompt.

local args, env = ...
local vfs = require("k.vfs")

local function err(msg, force)
  if not force then io.stderr:write("rm: " .. msg .. "\n") end
end

local recurse, force = false, false
local targets = {}
for i = 1, #args do
  local a = args[i]
  if a == "-r" or a == "-R" or a == "--recursive" then recurse = true
  elseif a == "-f" or a == "--force" then force = true
  elseif a == "-rf" or a == "-fr" then recurse, force = true, true
  elseif a == "--" then for j = i + 1, #args do targets[#targets + 1] = args[j] end; break
  elseif a:sub(1, 1) == "-" then err("unknown option: " .. a); return 2
  else targets[#targets + 1] = a end
end

if #targets == 0 then if force then return 0 end; err("missing operand"); return 2 end

local function abs(p)
  if p:sub(1, 1) ~= "/" then p = (env and env.PWD or "/") .. "/" .. p end
  return vfs.canonical(p)
end

local function rm_tree(path)
  if vfs.isdir(path) then
    if not recurse then err("cannot remove '" .. path .. "': Is a directory"); return false end
    local entries = vfs.list(path) or {}
    for _, name in ipairs(entries) do
      local child = path == "/" and ("/" .. name:gsub("/$", ""))
        or (path .. "/" .. name:gsub("/$", ""))
      if not rm_tree(child) then return false end
    end
  end
  local ok, e = vfs.remove(path)
  if not ok then err("cannot remove '" .. path .. "': " .. tostring(e), force); return force end
  return true
end

local rc = 0
for _, t in ipairs(targets) do
  local path = abs(t)
  if not vfs.exists(path) then
    if not force then err("cannot remove '" .. path .. "': No such file"); rc = 1 end
  elseif path == "/" then
    err("refusing to remove '/'"); rc = 1
  elseif not rm_tree(path) then rc = 1 end
end
return rc
