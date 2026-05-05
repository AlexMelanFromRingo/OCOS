-- /sys/lib/ui/widgets/menu.lua — pop-up menu of actions.
local widget = require("lib.ui.widget")
local function ucs_len(s) local u = _G.unicode; return u and u.len and u.len(s) or #s end

return function(props)
  return widget.new("menu", {
    state = { hover = nil },

    measure = function(self, max_w, max_h)
      local items = self.props.items or {}
      local w = 0
      for _, it in ipairs(items) do w = math.max(w, ucs_len(it.label)) end
      return math.min(w + 2, max_w), math.min(#items, max_h)
    end,

    draw = function(self, buffer, theme)
      local b = self.bounds
      local t = theme.menu or {}
      local bg = t.bg or theme.palette.surface
      local fg = t.fg or theme.palette.fg
      buffer:fill(b.x, b.y, b.w, b.h, " ", fg, bg)
      for i, it in ipairs(self.props.items or {}) do
        if i > b.h then break end
        local rfg, rbg = fg, bg
        if i == self.state.hover then
          rfg, rbg = t.hover_fg or 0xFFFFFF, t.hover_bg or theme.palette.accent
        end
        buffer:fill(b.x, b.y + i - 1, b.w, 1, " ", rfg, rbg)
        local n = math.min(ucs_len(it.label), b.w - 1)
        for j = 1, n do buffer:set(b.x + j, b.y + i - 1, it.label:sub(j, j), rfg, rbg) end
      end
      self.dirty = false
    end,

    on_event = function(self, ev)
      if not self:hit(ev.x or -1, ev.y or -1) and ev.type ~= "key" then
        if ev.type == "drop" or ev.type == "touch" then
          if self.props.on_close then self.props.on_close(self) end
          return false
        end
      end
      if ev.type == "drag" or ev.type == "touch" then
        local idx = ev.y - self.bounds.y + 1
        local items = self.props.items or {}
        if items[idx] then
          self.state.hover = idx; self:invalidate()
          if ev.type == "touch" then return true end
        end
      end
      if ev.type == "drop" and self:hit(ev.x, ev.y) then
        local idx = ev.y - self.bounds.y + 1
        local item = (self.props.items or {})[idx]
        if item and item.action then item.action(self) end
        if self.props.on_close then self.props.on_close(self) end
        return true
      end
      return false
    end,
  }, props)
end
