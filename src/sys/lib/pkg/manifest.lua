-- /sys/lib/pkg/manifest.lua — load and validate a package manifest.
--
-- A manifest is a Lua table returned from a chunk in <pkg>/manifest.cfg
-- with the schema described in docs/DESIGN.md §5.8. We accept the table
-- here, normalise defaults, and surface a structured error on any
-- problem so the installer can show the user a precise reason.

local M = {}

local semver = require("lib.codec.semver")
local vfs    = require("k.vfs")

local REQUIRED = { "id", "name", "version", "files" }

local function err(msg) return nil, "manifest: " .. msg end

function M.parse(src, source_name)
  local fn, lerr = load(src, "=" .. (source_name or "manifest"), "t", {})
  if not fn then return err("syntax: " .. lerr) end
  local ok, t = pcall(fn)
  if not ok then return err("evaluation: " .. tostring(t)) end
  if type(t) ~= "table" then return err("must return a table") end

  for _, k in ipairs(REQUIRED) do
    if t[k] == nil then return err("missing key: " .. k) end
  end

  local v, verr = semver.parse(t.version)
  if not v then return err(verr) end

  if type(t.files) ~= "table" or next(t.files) == nil then
    return err("files must be a non-empty table")
  end

  for path, meta in pairs(t.files) do
    if type(path) ~= "string" or path:sub(1, 1) == "/" then
      return err("file path must be relative: " .. tostring(path))
    end
    if type(meta) ~= "table" or type(meta.sha256) ~= "string" or #meta.sha256 ~= 64 then
      return err("file " .. path .. ": missing 64-char sha256")
    end
  end

  t.depends       = t.depends       or {}
  t.caps_required = t.caps_required or {}
  t.caps_optional = t.caps_optional or {}
  t.authors       = t.authors       or {}
  t.license       = t.license       or "unspecified"
  t.description   = t.description   or ""
  return t
end

function M.load_file(path)
  local src, e = vfs.read_all(path)
  if not src then return nil, "cannot read manifest: " .. tostring(e) end
  return M.parse(src, path)
end

local function fmt_key(k)
  if type(k) == "number" then return string.format("[%d]", k) end
  return string.format("[%q]", tostring(k))
end

function M.canonicalise(t)
  -- Stable Lua-table serialisation for hashing (and Ed25519 signing in M5).
  -- Keys are emitted in [...]=v form so any string is valid in the resulting
  -- table constructor.
  local lines = { "{" }
  local function emit(k, v, indent)
    indent = indent or "  "
    if type(v) == "string" then
      lines[#lines + 1] = string.format("%s%s = %q,", indent, fmt_key(k), v)
    elseif type(v) == "number" or type(v) == "boolean" then
      lines[#lines + 1] = string.format("%s%s = %s,", indent, fmt_key(k), tostring(v))
    elseif type(v) == "table" then
      local keys = {}
      for kk in pairs(v) do keys[#keys + 1] = kk end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      lines[#lines + 1] = string.format("%s%s = {", indent, fmt_key(k))
      for _, kk in ipairs(keys) do emit(kk, v[kk], indent .. "  ") end
      lines[#lines + 1] = indent .. "},"
    end
  end
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do emit(k, t[k]) end
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n")
end

return M
