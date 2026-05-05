-- /sys/lib/ui/widgets/window.lua — bordered, titled window with chrome.
--
-- Title bar: "  <title>...                          _ ▣ ×"
-- Body area: bounds.x+1..b.w-2, bounds.y+1..b.h-2  (one cell border).
-- Bottom-right has a "↘" resize grip when resizable.
--
-- User input is forwarded to callbacks the WM supplies:
--   on_close, on_min, on_max, on_focus, on_drag_start

local widget = require("lib.ui.widget")

local function clamp_title(t, w)
  t = t or ""
  if #t <= w then return t end
  if w <= 1 then return "…" end
  return t:sub(1, w - 1) .. "…"
end

return function(props)
  local W = widget.new("window", {
    state = { focused = false },

    measure = function(self, max_w, max_h)
      local cw, ch = max_w, max_h
      if self.children[1] then cw, ch = self.children[1]:measure(max_w - 2, max_h - 2) end
      return math.min(self.props.w or (cw + 2), max_w),
             math.min(self.props.h or (ch + 2), max_h)
    end,

    _layout_children = function(self)
      local b = self.bounds
      if self.children[1] then
        self.children[1]:layout(b.x + 1, b.y + 1, b.w - 2, b.h - 2)
      end
    end,

    draw = function(self, buffer, theme)
      local b = self.bounds
      local t = theme.window or {}
      local bg = t.bg or theme.palette.surface
      local fg = t.fg or theme.palette.fg
      local title_fg = t.title_fg or 0xFFFFFF
      local title_bg = self.state.focused
        and (t.title_bg or theme.palette.accent)
        or  (t.title_bg_unfocused or theme.palette.muted or 0x444444)
      local border = self.state.focused
        and (theme.palette.accent or 0x4FA0F0)
        or  (theme.palette.muted  or 0x666666)

      buffer:fill(b.x, b.y, b.w, b.h, " ", fg, bg)
      for x = b.x + 1, b.x + b.w - 2 do
        buffer:set(x, b.y + b.h - 1, "─", border, bg)
      end
      for y = b.y + 1, b.y + b.h - 1 do
        buffer:set(b.x,           y, "│", border, bg)
        buffer:set(b.x + b.w - 1, y, "│", border, bg)
      end
      buffer:set(b.x,           b.y + b.h - 1, "└", border, bg)
      buffer:set(b.x + b.w - 1, b.y + b.h - 1, "┘", border, bg)

      buffer:fill(b.x, b.y, b.w, 1, " ", title_fg, title_bg)
      local btn_count = 0
      if self.props.closable    ~= false then btn_count = btn_count + 1 end
      if self.props.maximisable ~= false then btn_count = btn_count + 1 end
      if self.props.minimisable ~= false then btn_count = btn_count + 1 end
      local title = clamp_title(self.props.title, math.max(0, b.w - 4 - btn_count * 2))
      for i = 1, #title do
        buffer:set(b.x + 1 + i, b.y, title:sub(i, i), title_fg, title_bg)
      end

      local cx = b.x + b.w - 2
      if self.props.closable ~= false then
        buffer:set(cx, b.y, "×", title_fg, title_bg); cx = cx - 2
      end
      if self.props.maximisable ~= false then
        local glyph = (self.wm_state and self.wm_state.state == "maximised") and "▢" or "▣"
        buffer:set(cx, b.y, glyph, title_fg, title_bg); cx = cx - 2
      end
      if self.props.minimisable ~= false then
        buffer:set(cx, b.y, "_", title_fg, title_bg)
      end

      if self.props.resizable ~= false then
        buffer:set(b.x + b.w - 1, b.y + b.h - 1, "↘", title_fg, bg)
      end

      for _, c in ipairs(self.children) do
        if c.visible then c:draw(buffer, theme) end
      end
      self.dirty = false
    end,

    on_event = function(self, ev)
      if ev.type == "touch" and self:hit(ev.x, ev.y) then
        if self.props.on_focus then self.props.on_focus(self) end
        local b = self.bounds
        if ev.y == b.y then
          local cx = b.x + b.w - 2
          if self.props.closable ~= false then
            if ev.x == cx then
              if self.props.on_close then self.props.on_close(self) end
              return true
            end
            cx = cx - 2
          end
          if self.props.maximisable ~= false then
            if ev.x == cx then
              if self.props.on_max then self.props.on_max(self) end
              return true
            end
            cx = cx - 2
          end
          if self.props.minimisable ~= false then
            if ev.x == cx then
              if self.props.on_min then self.props.on_min(self) end
              return true
            end
          end
          if self.props.on_drag_start then
            self.props.on_drag_start(self, "move", ev.x, ev.y)
          end
          return true
        end
        if self.props.resizable ~= false
            and ev.x == b.x + b.w - 1 and ev.y == b.y + b.h - 1 then
          if self.props.on_drag_start then
            self.props.on_drag_start(self, "resize", ev.x, ev.y)
          end
          return true
        end
      end
      for i = #self.children, 1, -1 do
        if self.children[i].visible and self.children[i]:on_event(ev) then return true end
      end
      return false
    end,
  }, props or {})
  W.wm_state = nil
  if props and props.body then W:add_child(props.body) end
  return W
end
