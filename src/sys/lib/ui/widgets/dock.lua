-- /sys/lib/ui/widgets/dock.lua — bottom strip of app launchers.
--
-- A dock takes a list of {label, icon?, on_click} and lays them out as
-- buttons in a horizontal row. The dock paints its own background (so the
-- desktop wallpaper doesn't show through the gap between buttons).

local widget = require("lib.ui.widget")
local layout = require("lib.ui.layout")
local button = require("lib.ui.widgets.button")
local function ucs_len(s) local u = _G.unicode; return u and u.len and u.len(s) or #s end

return function(props)
  local items = props.items or {}
  local children = {}
  for _, it in ipairs(items) do
    children[#children + 1] = button({
      text = it.label,
      on_click = it.on_click,
      w = ucs_len(it.label) + 4,
    })
  end
  local row = layout.row({ gap = 1, justify = "center", align = "center", children = children })

  return widget.new("dock", {
    measure = function(_, max_w, _) return max_w, 1 end,
    _layout_children = function(self)
      local b = self.bounds
      row:layout(b.x + 1, b.y, b.w - 2, 1)
    end,
    draw = function(self, buffer, theme)
      local b = self.bounds
      local bg = (theme.taskbar and theme.taskbar.bg) or theme.palette.surface
      buffer:fill(b.x, b.y, b.w, b.h, " ", theme.palette.fg, bg)
      row:draw(buffer, theme)
      self.dirty = false
    end,
    on_event = function(self, ev) return row:on_event(ev) end,
  }, props or {})
end
