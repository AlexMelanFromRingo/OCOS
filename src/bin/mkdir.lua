-- /bin/mkdir — create directories.
-- Usage: mkdir [-p] DIR...
--   -p   create parent directories as needed; do not error if a target
--        directory already exists.

local args, env = ...
local vfs = require("k.vfs")

local function err(msg) io.stderr:write("mkdir: " .. msg .. "\n") end

local parents = false
local targets = {}
for i = 1, #args do
  local a = args[i]
  if a == "-p" or a == "--parents" then parents = true
  elseif a == "--" then for j = i + 1, #args do targets[#targets + 1] = args[j] end; break
  elseif a:sub(1, 1) == "-" then err("unknown option: " .. a); return 2
  else targets[#targets + 1] = a end
end

if #targets == 0 then err("missing operand"); return 2 end

local function abs(p)
  if p:sub(1, 1) ~= "/" then p = (env and env.PWD or "/") .. "/" .. p end
  return vfs.canonical(p)
end

local function make_one(path)
  if vfs.exists(path) then
    if vfs.isdir(path) then
      if parents then return true end
      err("cannot create directory '" .. path .. "': File exists")
      return false
    end
    err("cannot create directory '" .. path .. "': not a directory")
    return false
  end
  if parents then
    local parent = path:match("(.*)/[^/]+$")
    if parent and parent ~= "" and not vfs.exists(parent) then
      if not make_one(parent) then return false end
    end
  end
  local ok, e = vfs.mkdir(path)
  if not ok then err("cannot create '" .. path .. "': " .. tostring(e)); return false end
  return true
end

local rc = 0
for _, t in ipairs(targets) do
  if not make_one(abs(t)) then rc = 1 end
end
return rc
