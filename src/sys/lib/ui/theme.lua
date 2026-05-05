-- /sys/lib/ui/theme.lua — load and access UI themes.
--
-- A theme is a Lua table at /etc/themes/<name>.lua. Widgets read symbolic
-- names like `theme.button.bg` rather than embedding 0x… literals. Themes
-- can extend each other through a `inherit` field that names the base.

local M = {}

local vfs = require("k.vfs")

local DEFAULT_DIR = "/etc/themes"

local function load_one(name)
  local path = DEFAULT_DIR .. "/" .. name .. ".lua"
  if not vfs.exists(path) then return nil, "theme not found: " .. name end
  local src = vfs.read_all(path)
  local fn, err = load(src, "=" .. path, "t", {})
  if not fn then return nil, "theme syntax: " .. tostring(err) end
  local ok, t = pcall(fn)
  if not ok then return nil, "theme eval: " .. tostring(t) end
  if type(t) ~= "table" then return nil, "theme must return a table" end
  return t
end

local function deep_merge(into, from)
  for k, v in pairs(from) do
    if type(v) == "table" and type(into[k]) == "table" then
      deep_merge(into[k], v)
    else
      into[k] = v
    end
  end
  return into
end

function M.load(name)
  local t, err = load_one(name); if not t then return nil, err end
  if t.inherit then
    local base, berr = M.load(t.inherit)
    if not base then return nil, "inherit '" .. t.inherit .. "': " .. tostring(berr) end
    t = deep_merge(base, t)
  end
  return t
end

local current
function M.set(theme) current = theme end
function M.current()
  if not current then current = assert(M.load("default")) end
  return current
end

return M
