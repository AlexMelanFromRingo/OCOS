-- /sys/lib/ui/widgets/wallpaper.lua — desktop background.
--
-- Modes:
--   solid colour (`color = 0xRRGGBB`)
--   pattern function (`pattern = function(x,y,theme) return ch,fg,bg end`)
--   per-user file (`pattern_path = "/home/<user>/.profile/wallpaper.lua"`)
--   built-in by name (`builtin = "stars" | "stripes"`)

local widget = require("lib.ui.widget")
local vfs    = require("k.vfs")

local function load_pattern_path(path)
  if not (path and vfs.exists(path)) then return nil end
  local src = vfs.read_all(path)
  if not src then return nil end
  local fn = load(src, "=" .. path, "t", { math = math, string = string })
  if not fn then return nil end
  local ok, p = pcall(fn)
  if ok and type(p) == "function" then return p end
end

local function load_builtin(name)
  if not name then return nil end
  local path = "/sys/lib/ui/wallpapers/" .. name .. ".lua"
  return load_pattern_path(path)
end

return function(props)
  props = props or {}
  if not props.pattern then
    props.pattern = load_pattern_path(props.pattern_path) or load_builtin(props.builtin)
  end
  return widget.new("wallpaper", {
    measure = function(_, max_w, max_h) return max_w, max_h end,
    draw = function(self, buffer, theme)
      local b = self.bounds
      local desktop_bg = (theme.desktop and theme.desktop.bg) or theme.palette.bg
      local color = self.props.color or desktop_bg
      if self.props.pattern then
        for y = b.y, b.y + b.h - 1 do
          for x = b.x, b.x + b.w - 1 do
            local ch, fg, bg = self.props.pattern(x, y, theme)
            buffer:set(x, y, ch or " ", fg or theme.palette.fg, bg or color)
          end
        end
      else
        buffer:fill(b.x, b.y, b.w, b.h, " ", theme.palette.fg, color)
      end
      self.dirty = false
    end,
  }, props)
end
