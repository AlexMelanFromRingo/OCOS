-- /sys/lib/ui/widgets/terminal.lua — embedded interactive terminal.
--
-- Owns three stream endpoints suitable for handing to exec.exec():
--   .stdin  — Stream<read> that blocks until the user types a line + Enter
--   .stdout — Stream<write> that the hosted process writes to
--   .stderr — Stream<write> in red
--
-- Internally maintains a scrollback array. Keystrokes routed to the widget
-- accumulate into a current input line; pressing Enter flushes that line
-- (with a trailing "\n") onto the stdin pipe and echoes it.

local widget = require("lib.ui.widget")
local pipe   = require("std.pipe")
local stream = require("std.stream")
local sched  = require("k.sched")

local function ucs_char(c) local u = _G.unicode; return u and u.char and u.char(c) or string.char(c) end

return function(props)
  local stdin_r, stdin_w = pipe.new()
  local self = widget.new("terminal", {}, props or {})
  -- Scrollback: each entry is { text=string, fg=int, bg=int } and represents
  -- a logical line. We split incoming bytes on "\n".
  self.state.lines    = { { text = "", fg = nil, bg = nil } }
  self.state.input    = ""
  self.state.input_col = 0
  self.state.scroll   = 0

  local function append(s, fg)
    local cur = self.state.lines[#self.state.lines]
    local i, n = 1, #s
    while i <= n do
      local nl = s:find("\n", i, true)
      if not nl then
        cur.text = cur.text .. s:sub(i)
        if fg then cur.fg = fg end
        i = n + 1
      else
        cur.text = cur.text .. s:sub(i, nl - 1)
        if fg then cur.fg = fg end
        self.state.lines[#self.state.lines + 1] = { text = "", fg = nil, bg = nil }
        cur = self.state.lines[#self.state.lines]
        i = nl + 1
      end
    end
    self:invalidate()
    computer.pushSignal("__ui_tick")
  end

  self.stdout = stream.new {
    _write = function(s, txt) append(txt, nil); return s end,
  }
  self.stderr = stream.new {
    _write = function(s, txt) append(txt, 0xE05050); return s end,
  }
  self.stdin  = stdin_r
  local stdin_writer = stdin_w

  self.measure = function(_, max_w, max_h) return max_w, max_h end

  self.draw = function(self_, buffer, theme)
    local b = self_.bounds
    local fg_default = theme.palette.fg
    local bg_default = theme.palette.bg
    buffer:fill(b.x, b.y, b.w, b.h, " ", fg_default, bg_default)
    -- Render the last `b.h - 1` lines (leaving the last row for the input).
    local visible_rows = b.h - 1
    local total = #self_.state.lines
    local first = math.max(1, total - visible_rows + 1 - self_.state.scroll)
    for row = 0, visible_rows - 1 do
      local entry = self_.state.lines[first + row]
      if entry then
        local fg = entry.fg or fg_default
        local text = entry.text:sub(1, b.w)
        for i = 1, #text do
          buffer:set(b.x + i - 1, b.y + row, text:sub(i, i), fg, bg_default)
        end
      end
    end
    -- Input line at the bottom with a leading prompt-marker so the user
    -- always sees their cursor even before the shell has emitted a prompt.
    local input_y = b.y + b.h - 1
    local prompt = "> "
    buffer:set(b.x,     input_y, prompt:sub(1, 1), theme.palette.accent, bg_default)
    buffer:set(b.x + 1, input_y, prompt:sub(2, 2), theme.palette.accent, bg_default)
    local input_text = self_.state.input
    for i = 1, math.min(#input_text, b.w - 2) do
      buffer:set(b.x + 1 + i, input_y, input_text:sub(i, i), fg_default, bg_default)
    end
    if self_.state.focused then
      local cx = b.x + 2 + math.min(self_.state.input_col, b.w - 3)
      local under = input_text:sub(self_.state.input_col + 1, self_.state.input_col + 1)
      buffer:set(cx, input_y, under ~= "" and under or " ", bg_default, theme.palette.accent)
    end
    self_.dirty = false
  end

  self.on_event = function(self_, ev)
    if ev.type == "touch" and self_:hit(ev.x, ev.y) then
      self_.state.focused = true; self_:invalidate(); return true
    end
    if ev.type == "key" and ev.down and self_.state.focused then
      local s = self_.state
      if ev.code == 28 or ev.code == 156 then
        local line = s.input
        s.input, s.input_col = "", 0
        append(line .. "\n", nil)
        pcall(stdin_writer.write, stdin_writer, line .. "\n")
        self_:invalidate(); return true
      elseif ev.code == 14 then
        if s.input_col > 0 then
          s.input = s.input:sub(1, s.input_col - 1) .. s.input:sub(s.input_col + 1)
          s.input_col = s.input_col - 1
          self_:invalidate()
        end
        return true
      elseif ev.code == 211 then
        if s.input_col < #s.input then
          s.input = s.input:sub(1, s.input_col) .. s.input:sub(s.input_col + 2)
          self_:invalidate()
        end
        return true
      elseif ev.code == 203 then s.input_col = math.max(0, s.input_col - 1); self_:invalidate(); return true
      elseif ev.code == 205 then s.input_col = math.min(#s.input, s.input_col + 1); self_:invalidate(); return true
      elseif ev.code == 199 then s.input_col = 0; self_:invalidate(); return true
      elseif ev.code == 207 then s.input_col = #s.input; self_:invalidate(); return true
      elseif ev.char and ev.char >= 32 then
        local glyph = ev.char < 128 and string.char(ev.char) or ucs_char(ev.char)
        s.input = s.input:sub(1, s.input_col) .. glyph .. s.input:sub(s.input_col + 1)
        s.input_col = s.input_col + 1
        self_:invalidate(); return true
      end
    end
    if ev.type == "scroll" and self_:hit(ev.x, ev.y) then
      local total = #self_.state.lines
      local visible = self_.bounds.h - 1
      local max_scroll = math.max(0, total - visible)
      self_.state.scroll = math.max(0, math.min(max_scroll, self_.state.scroll + ev.dir))
      self_:invalidate(); return true
    end
    return false
  end

  self.close_input = function() pcall(stdin_writer.close, stdin_writer) end
  return self
end
