-- /bin/pkg.lua — package-manager CLI.
local args = ...
local install = require("lib.pkg.install")
local db      = require("lib.pkg.db")

local function usage()
  io.stderr:write([[usage: pkg <command>
  install [-f] <dir|id|url>    install from local dir or registry
  uninstall <id>               remove an installed package
  list                         list installed packages
  info <id>                    show installed package metadata
  verify <id>                  re-check installed file checksums
  registry list                show configured registries
  registry add <name> <url>    add a registry
  registry remove <name>       remove a registry
]])
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
  local mfst, err
  if source:find("/", 1, true) and not source:match("^https?://") then
    mfst, err = install.install_dir(source, { force = force })
  else
    -- Bare id; resolve through configured registries.
    local registry = require("lib.pkg.registry")
    local base, version = registry.resolve(source)
    if not base then io.stderr:write("pkg: " .. tostring(version) .. "\n"); return 1 end
    mfst, err = registry.install(base, source, version, { force = force })
  end
  if not mfst then io.stderr:write("pkg: " .. tostring(err) .. "\n"); return 1 end
  local count = 0
  for _ in pairs(mfst.files) do count = count + 1 end
  print(string.format("installed %s %s (%d files)", mfst.id, mfst.version, count))
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

if cmd == "registry" then
  local sub = args[2]
  local registry = require("lib.pkg.registry")
  local vfs      = require("k.vfs")
  local CFG_PATH = "/etc/registries.cfg"

  local function save(list)
    local out = { "-- Configured package registries.",
                  "-- Edit by hand or via `pkg registry add/remove`.",
                  "return {" }
    for _, r in ipairs(list) do
      out[#out + 1] = string.format("  { name = %q, url = %q },", r.name, r.url)
    end
    out[#out + 1] = "}"; out[#out + 1] = ""
    return vfs.write_all(CFG_PATH, table.concat(out, "\n"))
  end

  if sub == "list" or not sub then
    local list = registry.read_registries()
    if #list == 0 then print("(no registries configured)"); return 0 end
    for _, r in ipairs(list) do print(string.format("%-20s  %s", r.name, r.url)) end
    return 0
  elseif sub == "add" then
    local name, url = args[3], args[4]
    if not (name and url) then
      io.stderr:write("usage: pkg registry add <name> <url>\n"); return 2
    end
    local list = registry.read_registries()
    for _, r in ipairs(list) do
      if r.name == name then io.stderr:write("pkg: registry exists: " .. name .. "\n"); return 1 end
    end
    list[#list + 1] = { name = name, url = url }
    local ok, err = save(list)
    if not ok then io.stderr:write("pkg: " .. tostring(err) .. "\n"); return 1 end
    print("added " .. name)
    return 0
  elseif sub == "remove" or sub == "rm" then
    local name = args[3]; if not name then io.stderr:write("usage: pkg registry remove <name>\n"); return 2 end
    local list = registry.read_registries()
    local kept = {}
    for _, r in ipairs(list) do if r.name ~= name then kept[#kept + 1] = r end end
    if #kept == #list then io.stderr:write("pkg: no such registry: " .. name .. "\n"); return 1 end
    local ok, err = save(kept)
    if not ok then io.stderr:write("pkg: " .. tostring(err) .. "\n"); return 1 end
    print("removed " .. name)
    return 0
  else
    io.stderr:write("pkg registry: unknown subcommand: " .. tostring(sub) .. "\n"); return 2
  end
end

return usage()
