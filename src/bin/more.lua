-- /bin/more — alias for /bin/less. The historical "more" predates less,
-- but on OCOS we use the same pager engine for both names so muscle
-- memory works either way.

local args, env = ...
local pager = require("lib.devtools.pager")
local vfs   = require("k.vfs")

local function err(msg) io.stderr:write("more: " .. msg .. "\n") end

local input, title
if args[1] then
  local path = args[1]
  if path:sub(1, 1) ~= "/" then path = (env and env.PWD or "/") .. "/" .. path end
  local s, e = vfs.read_all(path); if not s then err(tostring(e)); return 1 end
  input, title = s, path
else
  input, title = io.input():read("a") or "", "stdin"
end
return pager.show(input, { title = title, always = true, io = io })
