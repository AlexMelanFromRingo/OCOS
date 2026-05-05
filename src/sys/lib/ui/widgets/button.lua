-- /sys/lib/ui/widgets/button.lua — clickable button.
local widget = require("lib.ui.widget")

local function ucs_len(s)
  local u = _G.unicode; return u and u.len and u.len(s) or #s
end

local function ucs_sub(s, a, b)
  local u = _G.unicode; return u and u.sub and u.sub(s, a, b) or s:sub(a, b)
end

return function(props)
  return widget.new("button", {
    measure = function(self, max_w, max_h)
      local label = self.props.text or ""
      return math.min(max_w, ucs_len(label) + 2), math.min(1, max_h)
    end,

    draw = function(self, buffer, theme)
      local b = self.bounds
      local t = theme.button or {}
      local bg = t.bg or theme.palette.accent
      local fg = t.fg or 0xFFFFFF
      if self.props.disabled then
        bg, fg = t.disabled_bg or bg, t.disabled_fg or fg
      elseif self.state.pressed then
        bg, fg = t.pressed_bg or bg, t.pressed_fg or fg
      elseif self.state.hovered then
        bg, fg = t.hover_bg or bg, t.hover_fg or fg
      end
      buffer:fill(b.x, b.y, b.w, b.h, " ", fg, bg)
      local text = self.props.text or ""
      local n = ucs_len(text)
      local cx = b.x + math.max(0, math.floor((b.w - n) / 2))
      for i = 1, math.min(n, b.w) do
        buffer:set(cx + i - 1, b.y, ucs_sub(text, i, i), fg, bg)
      end
      self.dirty = false
    end,

    on_event = function(self, ev)
      if ev.type == "touch" and self:hit(ev.x, ev.y) then
        self.state.pressed = true; self:invalidate(); return true
      elseif ev.type == "drop" then
        local was_pressed = self.state.pressed
        self.state.pressed = false; self:invalidate()
        if was_pressed and self:hit(ev.x, ev.y) and not self.props.disabled then
          if self.props.on_click then self.props.on_click(self) end
          return true
        end
      end
      return false
    end,
  }, props)
end
