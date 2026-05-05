-- /sys/lib/lang.lua — translation dictionary loader.
--
-- Locales live at /etc/locale/<code>.lua and return a flat table from
-- string keys to translated strings. Lookup falls back to English when a
-- key is missing, then to the key itself wrapped in `<...>` so missing
-- translations are visually obvious.
--
-- Apps and the OS reach strings via `lang.t("dock.terminal")` etc.;
-- changing the active locale is one call (`lang.set("uk")`) plus an IPC
-- broadcast on `lang.changed` for live UI updates.

local M = {}

local vfs = require("k.vfs")
local ipc = require("k.ipc")

local current_code     -- string locale code
local current_table    -- {key -> translated}
local fallback_table   -- english, always loaded

local function load_locale(code)
  local path = "/etc/locale/" .. code .. ".lua"
  if not vfs.exists(path) then return nil, "locale not found: " .. code end
  local src = vfs.read_all(path)
  local fn, err = load(src or "", "=" .. path, "t", {})
  if not fn then return nil, "locale syntax: " .. tostring(err) end
  local ok, t = pcall(fn)
  if not ok or type(t) ~= "table" then return nil, "locale eval: " .. tostring(t) end
  return t
end

function M.set(code)
  local t, err = load_locale(code)
  if not t then return nil, err end
  current_code, current_table = code, t
  ipc.publish("lang.changed", { code = code })
  return true
end

function M.code() return current_code or "en" end

function M.t(key, ...)
  local v = current_table and current_table[key]
  if v == nil and fallback_table then v = fallback_table[key] end
  if v == nil then return "<" .. key .. ">" end
  if select("#", ...) > 0 then return string.format(v, ...) end
  return v
end

function M.list_available()
  local result = {}
  if vfs.isdir("/etc/locale") then
    for _, name in ipairs(vfs.list("/etc/locale") or {}) do
      if name:sub(-4) == ".lua" then result[#result + 1] = name:sub(1, -5) end
    end
    table.sort(result)
  end
  return result
end

-- Default activation: English fallback always loaded; runtime locale comes
-- from /etc/locale.cfg's `default` entry, which can be overridden by the
-- session environment.
do
  fallback_table = load_locale("en") or {}
  local cfg_path = "/etc/locale.cfg"
  if vfs.exists(cfg_path) then
    local src = vfs.read_all(cfg_path)
    local fn = load(src or "", "=" .. cfg_path, "t", {})
    if fn then
      local ok, cfg = pcall(fn)
      if ok and type(cfg) == "table" and cfg.default then
        local ok2 = M.set(cfg.default)
        if not ok2 then current_code, current_table = "en", fallback_table end
      end
    end
  end
  if not current_code then current_code, current_table = "en", fallback_table end
end

return M
