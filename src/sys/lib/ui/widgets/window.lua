-- /sys/lib/ui/widgets/window.lua — bordered, titled, draggable container.
local widget = require("lib.ui.widget")

local function ucs_len(s) local u = _G.unicode; return u and u.len and u.len(s) or #s end

return function(props)
  local w = widget.new("window", {
    state = { dragging = false, drag_dx = 0, drag_dy = 0 },

    measure = function(self, max_w, max_h)
      local cw, ch = max_w, max_h
      if self.children[1] then cw, ch = self.children[1]:measure(max_w - 2, max_h - 2) end
      return math.min(self.props.w or (cw + 2), max_w),
             math.min(self.props.h or (ch + 2), max_h)
    end,

    _layout_children = function(self)
      local b = self.bounds
      if self.children[1] then
        self.children[1]:layout(b.x + 1, b.y + 2, b.w - 2, b.h - 3)
      end
    end,

    draw = function(self, buffer, theme)
      local b = self.bounds
      local t = theme.window or {}
      local bg = t.bg or theme.palette.surface
      local fg = t.fg or theme.palette.fg
      buffer:fill(b.x, b.y, b.w, b.h, " ", fg, bg)
      buffer:fill(b.x, b.y, b.w, 1, " ", t.title_fg or 0xFFFFFF, t.title_bg or theme.palette.accent)
      local title = self.props.title or ""
      local n = math.min(ucs_len(title), b.w - 4)
      for i = 1, n do buffer:set(b.x + 1 + i, b.y, title:sub(i, i), t.title_fg or 0xFFFFFF, t.title_bg or theme.palette.accent) end
      if self.props.closable ~= false then
        buffer:set(b.x + b.w - 2, b.y, "x", t.title_fg or 0xFFFFFF, t.title_bg or theme.palette.accent)
      end
      for _, c in ipairs(self.children) do if c.visible then c:draw(buffer, theme) end end
      self.dirty = false
    end,

    on_event = function(self, ev)
      if ev.type == "touch" and self:hit(ev.x, ev.y) then
        if ev.y == self.bounds.y then
          if self.props.closable ~= false and ev.x == self.bounds.x + self.bounds.w - 2 then
            if self.props.on_close then self.props.on_close(self) end
            return true
          end
          self.state.dragging = true
          self.state.drag_dx = ev.x - self.bounds.x
          self.state.drag_dy = ev.y - self.bounds.y
          return true
        end
      elseif ev.type == "drag" and self.state.dragging then
        local nx, ny = ev.x - self.state.drag_dx, ev.y - self.state.drag_dy
        self.bounds.x, self.bounds.y = nx, ny
        if self.children[1] then
          self.children[1]:layout(nx + 1, ny + 2, self.bounds.w - 2, self.bounds.h - 3)
        end
        self:invalidate(); return true
      elseif ev.type == "drop" then
        self.state.dragging = false; return false
      end
      -- Forward unhandled events to children.
      for i = #self.children, 1, -1 do
        if self.children[i].visible and self.children[i]:on_event(ev) then return true end
      end
      return false
    end,
  }, props or {})
  if props and props.body then w:add_child(props.body) end
  return w
end
