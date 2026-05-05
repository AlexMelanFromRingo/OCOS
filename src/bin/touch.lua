-- /bin/touch — create empty files; on existing files, no-op.
--
-- OC managed filesystems expose lastModified read-only, so we cannot
-- bump the timestamp the way POSIX touch does. We document that limit
-- and create the file when missing — which is touch's most-used job
-- inside scripts.

local args, env = ...
local vfs = require("k.vfs")

local function err(msg) io.stderr:write("touch: " .. msg .. "\n") end

local targets = {}
for i = 1, #args do
  local a = args[i]
  if a == "--" then for j = i + 1, #args do targets[#targets + 1] = args[j] end; break
  elseif a:sub(1, 1) == "-" then err("unknown option: " .. a); return 2
  else targets[#targets + 1] = a end
end
if #targets == 0 then err("missing operand"); return 2 end

local function abs(p)
  if p:sub(1, 1) ~= "/" then p = (env and env.PWD or "/") .. "/" .. p end
  return vfs.canonical(p)
end

local rc = 0
for _, t in ipairs(targets) do
  local path = abs(t)
  if vfs.exists(path) then
    -- Cannot update mtime through the OC managed FS API; treat as no-op.
  else
    local ok, e = vfs.write_all(path, "")
    if not ok then err("'" .. path .. "': " .. tostring(e)); rc = 1 end
  end
end
return rc
