-- /bin/less — paginated viewer for stdin or a file.
-- Keys: ↓/j/Enter line-down, ↑/k line-up, Space/PgDn page-down, b/PgUp
-- page-up, g top, G bottom, q/Esc quit, mouse wheel scroll.

local args, env = ...
local pager = require("lib.devtools.pager")
local vfs   = require("k.vfs")

local function err(msg) io.stderr:write("less: " .. msg .. "\n") end

local function read_input()
  if args[1] then
    local path = args[1]
    if path:sub(1, 1) ~= "/" then path = (env and env.PWD or "/") .. "/" .. path end
    local s, e = vfs.read_all(path); if not s then err(tostring(e)); return nil end
    return s, path
  end
  return io.input():read("a") or "", "stdin"
end

local input, title = read_input()
if input == nil then return 1 end
return pager.show(input, { title = title, always = true })
