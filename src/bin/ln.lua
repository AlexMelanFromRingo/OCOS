-- /bin/ln — create a symbolic link.
-- Usage: ln -s TARGET LINK
--   * Hard links are not supported on the OC managed filesystem; we only
--     accept -s (symbolic).
--   * The link is encoded by k.vfs as a tiny <link>.lnk file holding the
--     target path; vfs.list/exists/open all transparently follow it.

local args, env = ...
local vfs = require("k.vfs")

local function err(msg) io.stderr:write("ln: " .. msg .. "\n") end

local symbolic = false
local positional = {}
for i = 1, #args do
  local a = args[i]
  if a == "-s" or a == "--symbolic" then symbolic = true
  elseif a == "--" then for j = i + 1, #args do positional[#positional + 1] = args[j] end; break
  elseif a:sub(1, 1) == "-" then err("unknown option: " .. a); return 2
  else positional[#positional + 1] = a end
end

if not symbolic then
  err("hard links are not supported; use ln -s TARGET LINK")
  return 2
end
if #positional ~= 2 then
  err("usage: ln -s TARGET LINK")
  return 2
end

local target, link = positional[1], positional[2]
if link:sub(1, 1) ~= "/" then
  link = vfs.canonical((env and env.PWD or "/") .. "/" .. link)
end

local ok, e = vfs.symlink(target, link)
if not ok then err(tostring(e)); return 1 end
return 0
