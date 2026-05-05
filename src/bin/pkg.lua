-- /bin/pkg.lua — package-manager CLI.
local args = ...
local install = require("lib.pkg.install")
local db      = require("lib.pkg.db")

local function usage()
  io.stderr:write("usage: pkg {install [-f] <dir> | uninstall <id> | list | info <id> | verify <id>}\n")
  return 2
end

local cmd = args[1]
if not cmd then return usage() end

if cmd == "install" then
  local force = false
  local i = 2
  if args[i] == "-f" then force = true; i = i + 1 end
  local source = args[i]
  if not source then return usage() end
  local mfst, err = install.install_dir(source, { force = force })
  if not mfst then io.stderr:write("pkg: " .. tostring(err) .. "\n"); return 1 end
  print(string.format("installed %s %s (%d files)", mfst.id, mfst.version,
        select("#", next(mfst.files))))
  return 0
end

if cmd == "uninstall" then
  local id = args[2]; if not id then return usage() end
  local ok, err = install.uninstall(id)
  if not ok then io.stderr:write("pkg: " .. tostring(err) .. "\n"); return 1 end
  print("removed " .. id)
  return 0
end

if cmd == "list" then
  for _, id in ipairs(db.list()) do
    local m = db.get(id)
    if m then print(string.format("%-30s %-10s  %s", m.id, m.version, m.description or "")) end
  end
  return 0
end

if cmd == "info" then
  local id = args[2]; if not id then return usage() end
  local m = db.get(id)
  if not m then io.stderr:write("pkg: not installed: " .. id .. "\n"); return 1 end
  print("id          : " .. m.id)
  print("name        : " .. m.name)
  print("version     : " .. m.version)
  print("license     : " .. m.license)
  print("authors     : " .. table.concat(m.authors, ", "))
  print("description : " .. m.description)
  print("files       :")
  for f in pairs(m.files) do print("  " .. f) end
  if next(m.depends) then
    print("depends     :")
    for k, v in pairs(m.depends) do print("  " .. k .. " " .. v) end
  end
  return 0
end

if cmd == "verify" then
  local id = args[2]; if not id then return usage() end
  local ok, err = install.verify(id)
  if ok then print("OK"); return 0 end
  io.stderr:write("FAIL " .. tostring(err) .. "\n"); return 1
end

return usage()
