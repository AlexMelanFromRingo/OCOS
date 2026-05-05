-- /sys/lib/ui/widgets/checkbox.lua — labelled binary toggle.
local widget = require("lib.ui.widget")

local function ucs_len(s) local u = _G.unicode; return u and u.len and u.len(s) or #s end

return function(props)
  return widget.new("checkbox", {
    state = { checked = props.checked == true },

    measure = function(self, max_w, max_h)
      local label = self.props.text or ""
      return math.min(4 + ucs_len(label), max_w), 1
    end,

    draw = function(self, buffer, theme)
      local b = self.bounds
      local t = theme.checkbox or {}
      local fg = t.fg or theme.palette.fg
      local accent = t.accent or theme.palette.accent
      local bg = self.props.bg or theme.palette.bg
      buffer:fill(b.x, b.y, b.w, b.h, " ", fg, bg)
      buffer:set(b.x, b.y, "[", fg, bg)
      buffer:set(b.x + 1, b.y, self.state.checked and "x" or " ",
                 self.state.checked and accent or fg, bg)
      buffer:set(b.x + 2, b.y, "]", fg, bg)
      local text = self.props.text or ""
      for i = 1, math.min(ucs_len(text), b.w - 4) do
        buffer:set(b.x + 3 + i, b.y, text:sub(i, i), fg, bg)
      end
      self.dirty = false
    end,

    on_event = function(self, ev)
      if ev.type == "drop" and self:hit(ev.x, ev.y) then
        self.state.checked = not self.state.checked
        if self.props.on_toggle then self.props.on_toggle(self, self.state.checked) end
        self:invalidate(); return true
      end
      return false
    end,
  }, props)
end
