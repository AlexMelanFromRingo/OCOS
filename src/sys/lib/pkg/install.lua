-- /sys/lib/pkg/install.lua — install / uninstall a package from a local
-- directory. Files declared in the manifest are SHA-256-verified, then
-- copied into the OCOS filesystem at the path given by the manifest's
-- `prefix` field (default "/"). The destination paths are recorded in the
-- per-package row in /var/db/pkg/<id>/installed.cfg so uninstall can undo.

local M = {}

local vfs      = require("k.vfs")
local sha256   = require("lib.codec.sha256")
local manifest = require("lib.pkg.manifest")
local db       = require("lib.pkg.db")
local semver   = require("lib.codec.semver")

local function read_file(path)
  local s, err = vfs.read_all(path); if not s then return nil, err end
  return s
end

local function write_file(path, data)
  local h, err = vfs.open(path, "w"); if not h then return nil, err end
  local ok, werr = h:write(data)
  h:close()
  if not ok then return nil, werr end
  return true
end

local function ensure_dir(path)
  local parts = {}
  for p in path:gmatch("[^/]+") do parts[#parts + 1] = p end
  local cur = ""
  for i = 1, #parts - 1 do
    cur = cur .. "/" .. parts[i]
    if not vfs.exists(cur) then pcall(vfs.mkdir, cur)
    elseif not vfs.isdir(cur) then return nil, "not a directory: " .. cur end
  end
  return true
end

local function check_dependencies(manifest_t)
  local missing = {}
  for dep_id, constraint in pairs(manifest_t.depends) do
    local installed = db.get(dep_id)
    if not installed then
      missing[#missing + 1] = dep_id .. " (any)"
    else
      local ok = semver.satisfies(installed.version, constraint)
      if not ok then
        missing[#missing + 1] = dep_id .. " " .. constraint ..
          " (have " .. installed.version .. ")"
      end
    end
  end
  if #missing > 0 then
    return nil, "unsatisfied deps: " .. table.concat(missing, ", ")
  end
  return true
end

local function record_installed(manifest_t, written)
  -- Persist a small footprint table next to the manifest so uninstall can
  -- enumerate the destination paths without re-reading the source bundle.
  local lines = { "return {" }
  for _, p in ipairs(written) do
    lines[#lines + 1] = string.format("  %q,", p)
  end
  lines[#lines + 1] = "}\n"
  local root = db.root()
  return vfs.write_all(root .. "/" .. manifest_t.id .. "/installed.cfg",
                       table.concat(lines, "\n"))
end

function M.install_dir(source_dir, opts)
  opts = opts or {}
  local mfst, err = manifest.load_file(source_dir .. "/manifest.cfg")
  if not mfst then return nil, err end

  if not opts.force then
    local existing = db.get(mfst.id)
    if existing then
      return nil, "already installed (" .. existing.version ..
        "). Use `pkg install -f` to reinstall."
    end
  end

  local ok, derr = check_dependencies(mfst)
  if not ok then return nil, derr end

  -- Verify every declared file before touching the destination.
  for rel, meta in pairs(mfst.files) do
    local data, e = read_file(source_dir .. "/" .. rel)
    if not data then return nil, "missing file " .. rel .. ": " .. tostring(e) end
    local digest = sha256.hex(data)
    if digest ~= meta.sha256:lower() then
      return nil, "checksum mismatch on " .. rel ..
        " (expected " .. meta.sha256 .. ", got " .. digest .. ")"
    end
  end

  -- Copy.
  local prefix = mfst.prefix or "/"
  local written = {}
  for rel, _ in pairs(mfst.files) do
    local data = read_file(source_dir .. "/" .. rel)
    local dest = prefix .. rel
    local _, derr2 = ensure_dir(dest); if derr2 then return nil, derr2 end
    local _, werr = write_file(dest, data)
    if werr then return nil, "write " .. dest .. ": " .. tostring(werr) end
    written[#written + 1] = dest
  end

  local _, perr = db.put(mfst); if perr then return nil, perr end
  local _, rerr = record_installed(mfst, written); if rerr then return nil, rerr end
  return mfst
end

function M.verify(id)
  local mfst, derr = db.get(id); if not mfst then return nil, derr or "not installed" end
  local prefix = mfst.prefix or "/"
  local bad = {}
  for rel, meta in pairs(mfst.files) do
    local data = read_file(prefix .. rel)
    if not data then bad[#bad + 1] = rel .. " (missing)"
    else
      local digest = sha256.hex(data)
      if digest ~= meta.sha256:lower() then
        bad[#bad + 1] = rel .. " (sha mismatch)"
      end
    end
  end
  if #bad > 0 then return false, table.concat(bad, ", ") end
  return true
end

function M.uninstall(id)
  local root = db.root(); if not root then return nil, "no db root" end
  local installed_cfg = root .. "/" .. id .. "/installed.cfg"
  if not vfs.exists(installed_cfg) then return nil, "not installed" end

  local list_src = read_file(installed_cfg)
  local fn, e = load(list_src, "=installed.cfg", "t", {})
  if not fn then return nil, "cannot parse installed.cfg: " .. tostring(e) end
  local ok, list = pcall(fn)
  if not ok or type(list) ~= "table" then return nil, "bad installed.cfg" end

  for _, p in ipairs(list) do pcall(vfs.remove, p) end
  return db.remove(id)
end

return M
