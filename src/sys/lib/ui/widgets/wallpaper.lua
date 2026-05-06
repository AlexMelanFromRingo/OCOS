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
  if not ok or type(p) ~= "function" then return nil end
  -- Convention: a wallpaper file may either return the pattern directly
  -- (signature `function(x,y,theme) → ch,fg,bg`) or a constructor that
  -- builds one (signature `function(opts) → pattern`). Probe by calling
  -- with no args; if that yields a function, the chunk was a constructor
  -- and the inner function is the real pattern. Otherwise treat the
  -- chunk's return value as the pattern itself.
  local probe_ok, probe = pcall(p)
  if probe_ok and type(probe) == "function" then return probe end
  return p
end

local function load_builtin(name)
  if not name then return nil end
  local path = "/sys/lib/ui/wallpapers/" .. name .. ".lua"
  return load_pattern_path(path)
end

return function(props)
  props = props or {}
  local function resolve()
    return load_pattern_path(props.pattern_path) or load_builtin(props.builtin)
  end
  if not props.pattern then props.pattern = resolve() end
  local W = widget.new("wallpaper", {
    measure = function(_, max_w, max_h) return max_w, max_h end,
    -- Re-read the wallpaper file from disk so Settings → Wallpaper takes
    -- effect without having to restart the desktop service.
    reload = function(self)
      self.props.pattern = resolve()
      self:invalidate()
    end,
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
  return W
end
