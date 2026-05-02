-- /bin/find.lua — recursive directory walk.
local args = ...
local vfs = require("k.vfs")

local roots = #args == 0 and { "." } or args

local function walk(root)
  if root:sub(1, 1) ~= "/" then root = vfs.canonical(root) end
  if not vfs.exists(root) then
    io.stderr:write("find: " .. root .. ": not found\n"); return 1
  end
  local stack = { root }
  while #stack > 0 do
    local p = table.remove(stack)
    print(p)
    if vfs.isdir(p) then
      local entries = vfs.list(p) or {}
      for i = #entries, 1, -1 do
        local sub = (p == "/" and "/" or p .. "/") .. entries[i]
        stack[#stack + 1] = sub
      end
    end
  end
end

for _, r in ipairs(roots) do walk(r) end
return 0
