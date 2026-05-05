-- /sys/lib/pkg/db.lua — installed-package registry persisted under
-- /var/db/pkg/<id>/manifest.cfg + installed.cfg.

local M = {}

local vfs = require("k.vfs")

local function pick_root()
  -- Prefer /var/db/pkg on the boot fs only if it's writable; otherwise look
  -- on the first writable mount and create the path there.
  if vfs.exists("/var/db/pkg") and vfs.exists("/var/db") then
    return "/var/db/pkg"
  end
  for _, m in ipairs(vfs.mounts()) do
    if m.prefix:sub(1, 5) == "/mnt/" then
      pcall(vfs.mkdir, m.prefix .. "/var")
      pcall(vfs.mkdir, m.prefix .. "/var/db")
      pcall(vfs.mkdir, m.prefix .. "/var/db/pkg")
      return m.prefix .. "/var/db/pkg"
    end
  end
end

function M.root() return pick_root() end

function M.list()
  local root = pick_root(); if not root then return {} end
  local entries = vfs.list(root) or {}
  local ids = {}
  for _, e in ipairs(entries) do
    if vfs.isdir(root .. "/" .. e) then ids[#ids + 1] = e end
  end
  table.sort(ids)
  return ids
end

function M.get(id)
  local root = pick_root(); if not root then return nil, "no db root" end
  local path = root .. "/" .. id .. "/manifest.cfg"
  if not vfs.exists(path) then return nil, "not installed" end
  return require("lib.pkg.manifest").load_file(path)
end

function M.put(manifest)
  local root = pick_root(); if not root then return nil, "no writable db root" end
  local dir = root .. "/" .. manifest.id
  pcall(vfs.mkdir, dir)
  local mfst = require("lib.pkg.manifest")
  local body = mfst.canonicalise(manifest)
  local ok, err = vfs.write_all(dir .. "/manifest.cfg", "return " .. body .. "\n")
  if not ok then return nil, err end
  return dir
end

function M.remove(id)
  local root = pick_root(); if not root then return nil, "no db root" end
  local dir = root .. "/" .. id
  if not vfs.exists(dir) then return nil, "not installed" end
  -- Recursive delete: enumerate then remove.
  local stack = { dir }
  local files, dirs = {}, {}
  while #stack > 0 do
    local d = table.remove(stack)
    dirs[#dirs + 1] = d
    for _, name in ipairs(vfs.list(d) or {}) do
      local sub = d .. "/" .. name
      if vfs.isdir(sub) then stack[#stack + 1] = sub
      else files[#files + 1] = sub end
    end
  end
  for _, f in ipairs(files) do pcall(vfs.remove, f) end
  for i = #dirs, 1, -1 do pcall(vfs.remove, dirs[i]) end
  return true
end

return M
