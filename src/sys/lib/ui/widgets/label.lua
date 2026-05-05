-- /sys/lib/ui/widgets/label.lua — a single-line text label.
local widget = require("lib.ui.widget")

local function unicode_len(s)
  local u = _G.unicode
  if u and u.len then return u.len(s) end
  return #s
end

local function unicode_sub(s, a, b)
  local u = _G.unicode
  if u and u.sub then return u.sub(s, a, b) end
  return s:sub(a, b)
end

local function clip(text, width)
  if unicode_len(text) <= width then return text end
  if width <= 1 then return unicode_sub(text, 1, width) end
  return unicode_sub(text, 1, width - 1) .. "…"
end

return function(props)
  return widget.new("label", {
    measure = function(self, max_w, max_h)
      local text = self.props.text or ""
      return math.min(unicode_len(text), max_w), 1
    end,
    draw = function(self, buffer, theme)
      local b = self.bounds
      local fg = self.props.fg or (theme.label and theme.label.fg) or theme.palette.fg
      local bg = self.props.bg or theme.palette.bg
      buffer:fill(b.x, b.y, b.w, b.h, " ", fg, bg)
      local text = clip(self.props.text or "", b.w)
      local x = b.x
      if self.props.align == "center" then
        x = b.x + math.floor((b.w - unicode_len(text)) / 2)
      elseif self.props.align == "end" then
        x = b.x + b.w - unicode_len(text)
      end
      for i = 1, unicode_len(text) do
        buffer:set(x + i - 1, b.y, unicode_sub(text, i, i), fg, bg)
      end
      self.dirty = false
    end,
  }, props)
end
