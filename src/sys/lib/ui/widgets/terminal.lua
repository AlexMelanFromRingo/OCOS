-- /sys/lib/ui/widgets/terminal.lua — embedded interactive terminal.
--
-- Owns three stream endpoints suitable for handing to exec.exec():
--   .stdin  — Stream<read> that blocks until the user types a line + Enter
--   .stdout — Stream<write> that the hosted process writes to (parses ANSI)
--   .stderr — Stream<write> in red
--
-- The scrollback stores per-line segment arrays (each segment carries its
-- own fg/bg) so a single line can mix colours emitted by `ls`, `grep`, etc.
-- through `\x1b[<n>m` sequences. Both streams set `_ansi = true` so callers
-- know they can emit ANSI codes — programs that don't, just write plain
-- text and inherit the line's last fg/bg.

local widget = require("lib.ui.widget")
local pipe   = require("std.pipe")
local stream = require("std.stream")

local function ucs_char(c) local u = _G.unicode; return u and u.char and u.char(c) or string.char(c) end

-- Iterate `s` one UTF-8 codepoint at a time. Each yield is the full
-- multi-byte glyph as a single string; gpu.set treats it as one cell.
local function each_glyph(s)
  local i, n = 1, #s
  return function()
    if i > n then return nil end
    local b = s:byte(i)
    local len
    if     b < 0x80 then len = 1
    elseif b < 0xC0 then len = 1            -- stray continuation; render as 1
    elseif b < 0xE0 then len = 2
    elseif b < 0xF0 then len = 3
    else                len = 4
    end
    if i + len - 1 > n then len = n - i + 1 end
    local g = s:sub(i, i + len - 1)
    i = i + len
    return g
  end
end

-- Standard ANSI 8-colour palette mapped to the OC palette OCOS uses
-- elsewhere. Bright variants get a brighter shade so users can tell
-- "30 vs 90" apart on a real T3 screen.
local ANSI_FG = {
  [30] = 0x404040, [31] = 0xCC4444, [32] = 0x6CCB6C, [33] = 0xE0C040,
  [34] = 0x4F8AF0, [35] = 0xCC66CC, [36] = 0x66CCCC, [37] = 0xCCCCCC,
  [90] = 0x808080, [91] = 0xE05050, [92] = 0x88EE88, [93] = 0xFFD060,
  [94] = 0x6BA0FF, [95] = 0xEE88EE, [96] = 0x88EEEE, [97] = 0xFFFFFF,
}
local ANSI_BG = {
  [40] = 0x202020, [41] = 0xCC4444, [42] = 0x6CCB6C, [43] = 0xE0C040,
  [44] = 0x4F8AF0, [45] = 0xCC66CC, [46] = 0x66CCCC, [47] = 0xCCCCCC,
  [100] = 0x808080,[101] = 0xE05050,[102] = 0x88EE88,[103] = 0xFFD060,
  [104] = 0x6BA0FF,[105] = 0xEE88EE,[106] = 0x88EEEE,[107] = 0xFFFFFF,
}

return function(props)
  local stdin_r, stdin_w = pipe.new()
  local self = widget.new("terminal", {}, props or {})
  -- Each scrollback line is { segments = { {text, fg, bg}, ... } }.
  -- Drawing walks the segments left-to-right; appending text grows the
  -- last segment if its colours match, else starts a new one.
  local function blank_line() return { segments = { { text = "", fg = nil, bg = nil } } } end
  self.state.lines     = { blank_line() }
  self.state.input     = ""
  self.state.input_col = 0
  self.state.scroll    = 0
  self.state.fg        = nil                           -- current ANSI fg
  self.state.bg        = nil                           -- current ANSI bg

  local function last_segment(line)
    return line.segments[#line.segments]
  end

  local function push_text(line, text, fg, bg)
    if text == "" then return end
    local seg = last_segment(line)
    if seg.fg == fg and seg.bg == bg then
      seg.text = seg.text .. text
    else
      line.segments[#line.segments + 1] = { text = text, fg = fg, bg = bg }
    end
  end

  local function apply_sgr(codes, override_fg)
    -- override_fg pins fg (used for stderr → red regardless of program output)
    if #codes == 0 then codes = { 0 } end
    for _, n in ipairs(codes) do
      if n == 0 then
        self.state.fg = nil; self.state.bg = nil
      elseif n == 39 then
        self.state.fg = nil
      elseif n == 49 then
        self.state.bg = nil
      elseif ANSI_FG[n] then
        if not override_fg then self.state.fg = ANSI_FG[n] end
      elseif ANSI_BG[n] then
        self.state.bg = ANSI_BG[n]
      end
    end
  end

  local function append(s, override_fg)
    -- Walk the bytes; when we hit ESC `[` <digits;digits> `m`, update
    -- the current SGR state. Everything else accumulates as plain text
    -- in the current segment.
    local i, n = 1, #s
    local cur = self.state.lines[#self.state.lines]
    local function flush_chunk(chunk)
      if chunk == "" then return end
      local fg = override_fg or self.state.fg
      local bg = self.state.bg
      while #chunk > 0 do
        local nl = chunk:find("\n", 1, true)
        if not nl then push_text(cur, chunk, fg, bg); break end
        push_text(cur, chunk:sub(1, nl - 1), fg, bg)
        self.state.lines[#self.state.lines + 1] = blank_line()
        cur = self.state.lines[#self.state.lines]
        chunk = chunk:sub(nl + 1)
      end
    end
    while i <= n do
      local esc = s:find("\27", i, true)
      if not esc then flush_chunk(s:sub(i)); break end
      flush_chunk(s:sub(i, esc - 1))
      -- Parse "ESC [ <params> m". Anything else: we just drop the ESC.
      if s:byte(esc + 1) == 91 then           -- '['
        local close = s:find("[a-zA-Z]", esc + 2)
        if close and s:byte(close) == 109 then
          local params = s:sub(esc + 2, close - 1)
          local codes = {}
          for c in (params .. ";"):gmatch("(%-?%d*);") do
            codes[#codes + 1] = tonumber(c) or 0
          end
          apply_sgr(codes, override_fg)
          i = close + 1
        else
          -- Unknown CSI sequence — skip up to and including the final byte.
          i = (close or n) + 1
        end
      else
        i = esc + 1                            -- bare ESC; drop it
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
  self.stdout._ansi   = true                          -- callers may emit \x1b[..m
  self.stderr._ansi   = true
  self.stdout._isatty = false                          -- pager etc. should use the dump path
  self.stderr._isatty = false
  self.stdin = stdin_r
  local stdin_writer = stdin_w

  self.measure = function(_, max_w, max_h) return max_w, max_h end

  self.draw = function(self_, buffer, theme)
    local b = self_.bounds
    local fg_default = theme.palette.fg
    local bg_default = theme.palette.bg
    buffer:fill(b.x, b.y, b.w, b.h, " ", fg_default, bg_default)
    local visible_rows = b.h - 1
    local total = #self_.state.lines
    local first = math.max(1, total - visible_rows + 1 - self_.state.scroll)
    for row = 0, visible_rows - 1 do
      local entry = self_.state.lines[first + row]
      if entry then
        local col = 0
        for _, seg in ipairs(entry.segments) do
          local sfg = seg.fg or fg_default
          local sbg = seg.bg or bg_default
          for g in each_glyph(seg.text) do
            if col >= b.w then break end
            buffer:set(b.x + col, b.y + row, g, sfg, sbg)
            col = col + 1
          end
          if col >= b.w then break end
        end
      end
    end
    local input_y = b.y + b.h - 1
    local prompt = "> "
    buffer:set(b.x,     input_y, prompt:sub(1, 1), theme.palette.accent, bg_default)
    buffer:set(b.x + 1, input_y, prompt:sub(2, 2), theme.palette.accent, bg_default)
    local glyphs = {}
    for g in each_glyph(self_.state.input) do glyphs[#glyphs + 1] = g end
    for i = 1, math.min(#glyphs, b.w - 2) do
      buffer:set(b.x + 1 + i, input_y, glyphs[i], fg_default, bg_default)
    end
    if self_.state.focused then
      local cx = b.x + 2 + math.min(self_.state.input_col, b.w - 3)
      local under = glyphs[self_.state.input_col + 1]
      buffer:set(cx, input_y, under or " ", bg_default, theme.palette.accent)
    end
    self_.dirty = false
  end

  self.on_event = function(self_, ev)
    if ev.type == "touch" and self_:hit(ev.x, ev.y) then
      self_.state.focused = true; self_:invalidate(); return true
    end
    if ev.type == "key" and ev.down and self_.state.focused then
      local s = self_.state
      local glyphs = {}
      for g in each_glyph(s.input) do glyphs[#glyphs + 1] = g end
      local function rebuild() s.input = table.concat(glyphs) end
      if ev.code == 28 or ev.code == 156 then
        local line = s.input
        s.input, s.input_col = "", 0
        append(line .. "\n", nil)
        pcall(stdin_writer.write, stdin_writer, line .. "\n")
        self_:invalidate(); return true
      elseif ev.code == 14 then
        if s.input_col > 0 then
          table.remove(glyphs, s.input_col); rebuild()
          s.input_col = s.input_col - 1
          self_:invalidate()
        end
        return true
      elseif ev.code == 211 then
        if s.input_col < #glyphs then
          table.remove(glyphs, s.input_col + 1); rebuild()
          self_:invalidate()
        end
        return true
      elseif ev.code == 203 then s.input_col = math.max(0, s.input_col - 1); self_:invalidate(); return true
      elseif ev.code == 205 then s.input_col = math.min(#glyphs, s.input_col + 1); self_:invalidate(); return true
      elseif ev.code == 199 then s.input_col = 0; self_:invalidate(); return true
      elseif ev.code == 207 then s.input_col = #glyphs; self_:invalidate(); return true
      elseif ev.char and ev.char >= 32 then
        local glyph = ev.char < 128 and string.char(ev.char) or ucs_char(ev.char)
        table.insert(glyphs, s.input_col + 1, glyph); rebuild()
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
