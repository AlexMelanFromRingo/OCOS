-- /sys/lib/pkg/registry.lua — remote package registry adapter.
--
-- A registry is a small HTTP-served directory laid out as:
--   <base>/index.cfg                  -- Lua table { id = "...", description = "..." }
--   <base>/<id>/<version>/manifest.cfg
--   <base>/<id>/<version>/payload.tar
--
-- We do NOT implement tar parsing in M5 — payloads are unpacked client-side
-- by the existing manifest-driven file copy if the registry serves the
-- payload as a flat directory tree under the version folder. So the layout
-- the loader actually needs is:
--   <base>/<id>/<version>/manifest.cfg
--   <base>/<id>/<version>/<file-listed-in-manifest.files>
-- and `pkg install <id>` stages every declared file via HTTP into a temp
-- directory, then hands the directory off to install.install_dir.

local M = {}

local vfs       = require("k.vfs")
local internet  = require("drv.internet")
local install   = require("lib.pkg.install")
local manifest  = require("lib.pkg.manifest")

local function http_get(url, opts)
  opts = opts or {}
  local body, status = internet.http_request(url, opts)
  if not body then return nil, status end
  if type(status) == "number" and (status < 200 or status >= 300) then
    return nil, "HTTP " .. tostring(status) .. " on " .. url
  end
  return body
end

function M.fetch_index(base_url)
  local body, err = http_get(base_url:gsub("/+$", "") .. "/index.cfg")
  if not body then return nil, err end
  local fn, lerr = load(body, "=index.cfg", "t", {})
  if not fn then return nil, "index syntax: " .. tostring(lerr) end
  local ok, t = pcall(fn)
  if not ok or type(t) ~= "table" then return nil, "index eval: " .. tostring(t) end
  return t
end

local function pkg_url(base, id, version, sub)
  return base:gsub("/+$", "") .. "/" .. id .. "/" .. version .. "/" .. sub
end

local function ensure_temp_root()
  for _, m in ipairs(vfs.mounts()) do
    if m.prefix:sub(1, 5) == "/mnt/" then
      local t = m.prefix .. "/var/tmp"
      pcall(vfs.mkdir, m.prefix .. "/var")
      pcall(vfs.mkdir, t)
      return t
    end
  end
end

local function ensure_dir(path)
  local parts, cur = {}, ""
  for p in path:gmatch("[^/]+") do parts[#parts + 1] = p end
  for i = 1, #parts - 1 do
    cur = cur .. "/" .. parts[i]
    if not vfs.exists(cur) then pcall(vfs.mkdir, cur) end
  end
end

function M.install(base_url, id, version, opts)
  -- Stage manifest + every declared file under a temp directory, then defer
  -- to install.install_dir which already does sha verification + DB writes.
  if not internet.has_internet() then return nil, "no internet" end

  local manifest_body, err = http_get(pkg_url(base_url, id, version, "manifest.cfg"))
  if not manifest_body then return nil, "manifest: " .. tostring(err) end
  local mfst, mferr = manifest.parse(manifest_body, "<remote>")
  if not mfst then return nil, mferr end
  if mfst.id ~= id then return nil, "manifest id mismatch: " .. mfst.id .. " vs " .. id end
  if mfst.version ~= version then return nil, "manifest version mismatch" end

  local tmp = ensure_temp_root(); if not tmp then return nil, "no temp root" end
  local stage = tmp .. "/pkg-" .. id:gsub("%W", "_") .. "-" .. version:gsub("%W", "_")
  pcall(vfs.mkdir, stage)
  vfs.write_all(stage .. "/manifest.cfg", manifest_body)

  for rel in pairs(mfst.files) do
    local body, ferr = http_get(pkg_url(base_url, id, version, rel))
    if not body then return nil, "fetch " .. rel .. ": " .. tostring(ferr) end
    ensure_dir(stage .. "/" .. rel)
    vfs.write_all(stage .. "/" .. rel, body)
  end

  return install.install_dir(stage, opts or {})
end

function M.read_registries()
  -- /etc/registries.cfg is a Lua table:
  --   return { { name = "official", url = "https://..." }, ... }
  if not vfs.exists("/etc/registries.cfg") then return {} end
  local src = vfs.read_all("/etc/registries.cfg")
  local fn = load(src, "=/etc/registries.cfg", "t", {})
  if not fn then return {} end
  local ok, t = pcall(fn)
  if not ok or type(t) ~= "table" then return {} end
  return t
end

function M.resolve(id)
  -- Scan configured registries' indexes until one knows about `id`.
  for _, reg in ipairs(M.read_registries()) do
    local idx, err = M.fetch_index(reg.url)
    if idx then
      for _, entry in ipairs(idx.packages or {}) do
        if entry.id == id then
          return reg.url, entry.version
        end
      end
    end
  end
  return nil, "package not found in any registry"
end

return M
