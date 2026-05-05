-- /sys/lib/ui/widgets/wallpaper.lua — desktop background.
--
-- Two modes: solid colour (default) and pattern (a function the caller
-- supplies that returns ch, fg, bg per cell). Patterns enable the rain /
-- dvd / starfield wallpapers without the compositor knowing about them.

local widget = require("lib.ui.widget")

return function(props)
  return widget.new("wallpaper", {
    measure = function(self, max_w, max_h) return max_w, max_h end,
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
  }, props or {})
end
