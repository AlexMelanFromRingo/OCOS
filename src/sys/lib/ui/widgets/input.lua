-- /sys/lib/ui/widgets/input.lua — single-line text input.
local widget = require("lib.ui.widget")

local function ucs_len(s) local u = _G.unicode; return u and u.len and u.len(s) or #s end
local function ucs_sub(s, a, b) local u = _G.unicode; return u and u.sub and u.sub(s, a, b) or s:sub(a, b) end
local function ucs_char(c) local u = _G.unicode; return u and u.char and u.char(c) or string.char(c) end

return function(props)
  return widget.new("input", {
    state = { value = props.value or "", cursor = ucs_len(props.value or "") },

    measure = function(self, max_w, max_h)
      return math.min(self.props.width or 16, max_w), 1
    end,

    draw = function(self, buffer, theme)
      local b = self.bounds
      local t = theme.input or {}
      local bg = self.state.focused and (t.focused_bg or t.bg) or t.bg or theme.palette.surface
      local fg = self.state.focused and (t.focused_fg or t.fg) or t.fg or theme.palette.fg
      buffer:fill(b.x, b.y, b.w, b.h, " ", fg, bg)
      local text = self.state.value or ""
      if text == "" and self.props.placeholder and not self.state.focused then
        local ph = self.props.placeholder
        local pfg = t.placeholder or theme.palette.muted
        for i = 1, math.min(ucs_len(ph), b.w) do
          buffer:set(b.x + i - 1, b.y, ucs_sub(ph, i, i), pfg, bg)
        end
      else
        for i = 1, math.min(ucs_len(text), b.w) do
          buffer:set(b.x + i - 1, b.y, ucs_sub(text, i, i), fg, bg)
        end
      end
      if self.state.focused then
        local cx = b.x + math.min(self.state.cursor, b.w - 1)
        local cur_fg = (t.cursor or theme.palette.accent)
        local under = ucs_sub(text, self.state.cursor + 1, self.state.cursor + 1)
        buffer:set(cx, b.y, under ~= "" and under or " ", bg, cur_fg)
      end
      self.dirty = false
    end,

    on_event = function(self, ev)
      if ev.type == "touch" then
        if self:hit(ev.x, ev.y) then
          self.state.focused = true
          self.state.cursor = math.max(0, math.min(ucs_len(self.state.value), ev.x - self.bounds.x))
          self:invalidate(); return true
        else
          if self.state.focused then self.state.focused = false; self:invalidate() end
        end
      end
      if ev.type == "key" and ev.down and self.state.focused then
        local code = ev.code
        if code == 28 or code == 156 then
          if self.props.on_submit then self.props.on_submit(self, self.state.value) end
          return true
        elseif code == 14 then  -- backspace
          if self.state.cursor > 0 then
            local v = self.state.value
            self.state.value = ucs_sub(v, 1, self.state.cursor - 1) .. ucs_sub(v, self.state.cursor + 1)
            self.state.cursor = self.state.cursor - 1
            if self.props.on_change then self.props.on_change(self, self.state.value) end
            self:invalidate()
          end
          return true
        elseif code == 211 then  -- delete
          local v = self.state.value
          if self.state.cursor < ucs_len(v) then
            self.state.value = ucs_sub(v, 1, self.state.cursor) .. ucs_sub(v, self.state.cursor + 2)
            if self.props.on_change then self.props.on_change(self, self.state.value) end
            self:invalidate()
          end
          return true
        elseif code == 203 then  -- left
          self.state.cursor = math.max(0, self.state.cursor - 1); self:invalidate(); return true
        elseif code == 205 then  -- right
          self.state.cursor = math.min(ucs_len(self.state.value), self.state.cursor + 1); self:invalidate(); return true
        elseif code == 199 then  -- home
          self.state.cursor = 0; self:invalidate(); return true
        elseif code == 207 then  -- end
          self.state.cursor = ucs_len(self.state.value); self:invalidate(); return true
        elseif ev.char and ev.char >= 32 then
          local v = self.state.value
          local glyph = ev.char < 128 and string.char(ev.char) or ucs_char(ev.char)
          self.state.value = ucs_sub(v, 1, self.state.cursor) .. glyph .. ucs_sub(v, self.state.cursor + 1)
          self.state.cursor = self.state.cursor + 1
          if self.props.on_change then self.props.on_change(self, self.state.value) end
          self:invalidate()
          return true
        end
      end
      return false
    end,
  }, props)
end
