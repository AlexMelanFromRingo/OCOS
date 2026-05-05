-- /sys/lib/ui/widgets/list.lua — vertical scrollable list.
local widget = require("lib.ui.widget")

local function ucs_len(s) local u = _G.unicode; return u and u.len and u.len(s) or #s end
local function ucs_sub(s, a, b) local u = _G.unicode; return u and u.sub and u.sub(s, a, b) or s:sub(a, b) end

return function(props)
  return widget.new("list", {
    state = { selected = props.selected or 1, scroll = 0 },

    measure = function(self, max_w, max_h)
      return math.min(self.props.width or max_w, max_w),
             math.min(self.props.height or #(self.props.items or {}), max_h)
    end,

    draw = function(self, buffer, theme)
      local b = self.bounds
      local t = theme.list or {}
      local bg = t.bg or theme.palette.surface
      local fg = t.fg or theme.palette.fg
      buffer:fill(b.x, b.y, b.w, b.h, " ", fg, bg)
      local items = self.props.items or {}
      for row = 0, b.h - 1 do
        local idx = row + 1 + self.state.scroll
        local item = items[idx]
        if item then
          local label = self.props.format and self.props.format(item) or tostring(item)
          local row_fg, row_bg = fg, bg
          if idx == self.state.selected then
            row_fg = t.selected_fg or 0xFFFFFF
            row_bg = t.selected_bg or theme.palette.accent
          end
          buffer:fill(b.x, b.y + row, b.w, 1, " ", row_fg, row_bg)
          local n = math.min(ucs_len(label), b.w)
          for i = 1, n do
            buffer:set(b.x + i - 1, b.y + row, ucs_sub(label, i, i), row_fg, row_bg)
          end
        end
      end
      self.dirty = false
    end,

    on_event = function(self, ev)
      local items = self.props.items or {}
      if ev.type == "touch" and self:hit(ev.x, ev.y) then
        local idx = ev.y - self.bounds.y + 1 + self.state.scroll
        if items[idx] then
          self.state.selected = idx
          if self.props.on_select then self.props.on_select(self, items[idx], idx) end
          self:invalidate(); return true
        end
      end
      if ev.type == "scroll" and self:hit(ev.x, ev.y) then
        local max_scroll = math.max(0, #items - self.bounds.h)
        self.state.scroll = math.max(0, math.min(max_scroll, self.state.scroll - ev.dir))
        self:invalidate(); return true
      end
      if ev.type == "key" and ev.down and self.state.focused then
        if ev.code == 200 then  -- up
          self.state.selected = math.max(1, self.state.selected - 1)
          if self.state.selected - 1 < self.state.scroll then self.state.scroll = self.state.selected - 1 end
          self:invalidate(); return true
        elseif ev.code == 208 then  -- down
          self.state.selected = math.min(#items, self.state.selected + 1)
          if self.state.selected > self.state.scroll + self.bounds.h then
            self.state.scroll = self.state.selected - self.bounds.h
          end
          self:invalidate(); return true
        elseif ev.code == 28 then  -- enter
          if self.props.on_activate and items[self.state.selected] then
            self.props.on_activate(self, items[self.state.selected], self.state.selected)
          end
          return true
        end
      end
      return false
    end,
  }, props)
end
