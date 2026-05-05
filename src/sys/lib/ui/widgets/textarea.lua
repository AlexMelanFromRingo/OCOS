-- /sys/lib/ui/widgets/textarea.lua — multi-line text editing widget.
--
-- Holds a list of lines; cursor moves character-wise within a line and
-- line-wise across lines. Supports basic editing, scroll, and Lua-syntax
-- highlight (keywords + comments + strings + numbers) when `highlight`
-- prop is set to "lua".

local widget = require("lib.ui.widget")

local function ucs_len(s) local u = _G.unicode; return u and u.len and u.len(s) or #s end
local function ucs_sub(s, a, b) local u = _G.unicode; return u and u.sub and u.sub(s, a, b) or s:sub(a, b) end
local function ucs_char(c) local u = _G.unicode; return u and u.char and u.char(c) or string.char(c) end

local LUA_KEYWORDS = {}
for _, w in ipairs({
  "and","break","do","else","elseif","end","false","for","function","goto","if","in",
  "local","nil","not","or","repeat","return","then","true","until","while",
}) do LUA_KEYWORDS[w] = true end

local function highlight_line(line, theme)
  -- Returns an array of {start, len, fg} segments. The renderer paints text
  -- with the default fg first, then over-writes runs with the segment fg.
  local segs = {}
  local i, n = 1, #line
  local fg_str  = theme.input and (theme.input.fg or 0xE6E6E6) or 0xE6E6E6
  local fg_kw   = theme.palette.accent or 0x4F8AF0
  local fg_str2 = theme.palette.warn   or 0xE0A040
  local fg_num  = theme.palette.ok     or 0x6CCB6C
  local fg_com  = theme.palette.muted  or 0x808080

  while i <= n do
    local c = line:sub(i, i)
    if c == "-" and line:sub(i + 1, i + 1) == "-" then
      segs[#segs + 1] = { i, n - i + 1, fg_com }; break
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        if line:sub(j, j) == "\\" then j = j + 2
        elseif line:sub(j, j) == c then j = j + 1; break
        else j = j + 1 end
      end
      segs[#segs + 1] = { i, j - i, fg_str2 }
      i = j
    elseif c:match("[%w_]") then
      local j = i
      while j <= n and line:sub(j, j):match("[%w_]") do j = j + 1 end
      local word = line:sub(i, j - 1)
      if LUA_KEYWORDS[word] then segs[#segs + 1] = { i, #word, fg_kw }
      elseif word:match("^%d") then segs[#segs + 1] = { i, #word, fg_num } end
      i = j
    else
      i = i + 1
    end
  end
  return segs
end

return function(props)
  local lines = {}
  for line in (props.text or ""):gmatch("([^\n]*)\n?") do lines[#lines + 1] = line end
  if #lines == 0 then lines = { "" } end

  return widget.new("textarea", {
    state = { lines = lines, row = 1, col = 0, scroll = 0 },

    measure = function(_, max_w, max_h) return max_w, max_h end,

    draw = function(self, buffer, theme)
      local b = self.bounds
      local fg = (theme.input and theme.input.fg) or theme.palette.fg
      local bg = (theme.input and theme.input.bg) or theme.palette.bg
      local lineno_fg = theme.palette.muted
      buffer:fill(b.x, b.y, b.w, b.h, " ", fg, bg)
      local left = 5                                   -- line-number gutter
      for row = 0, b.h - 1 do
        local line_idx = row + 1 + self.state.scroll
        local line = self.state.lines[line_idx]
        if line then
          local n = string.format("%4d", line_idx)
          for i = 1, 4 do buffer:set(b.x + i - 1, b.y + row, n:sub(i, i), lineno_fg, bg) end
          buffer:set(b.x + 4, b.y + row, " ", lineno_fg, bg)
          local visible = line:sub(1, b.w - left)
          for i = 1, #visible do
            buffer:set(b.x + left + i - 1, b.y + row, visible:sub(i, i), fg, bg)
          end
          if self.props.highlight == "lua" then
            for _, seg in ipairs(highlight_line(visible, theme)) do
              for j = 0, seg[2] - 1 do
                local x = b.x + left + seg[1] - 1 + j
                if x < b.x + b.w then
                  buffer:set(x, b.y + row, visible:sub(seg[1] + j, seg[1] + j), seg[3], bg)
                end
              end
            end
          end
        end
      end
      if self.state.focused then
        local cur_row = self.state.row - self.state.scroll
        if cur_row >= 1 and cur_row <= b.h then
          local cur_x = b.x + left + math.min(self.state.col, b.w - left - 1)
          local cy = b.y + cur_row - 1
          local under = self.state.lines[self.state.row]:sub(self.state.col + 1, self.state.col + 1)
          buffer:set(cur_x, cy, under ~= "" and under or " ", bg, theme.palette.accent)
        end
      end
      self.dirty = false
    end,

    on_event = function(self, ev)
      if ev.type == "touch" and self:hit(ev.x, ev.y) then
        self.state.focused = true
        local row = ev.y - self.bounds.y + 1 + self.state.scroll
        if self.state.lines[row] then self.state.row = row end
        self.state.col = math.max(0, math.min(#self.state.lines[self.state.row], ev.x - self.bounds.x - 5))
        self:invalidate(); return true
      end
      if ev.type == "key" and ev.down and self.state.focused then
        local s = self.state
        local cur_line = s.lines[s.row]
        local function update_scroll()
          if s.row - 1 < s.scroll then s.scroll = s.row - 1
          elseif s.row > s.scroll + self.bounds.h then s.scroll = s.row - self.bounds.h end
        end
        if ev.code == 200 and s.row > 1 then
          s.row = s.row - 1
          s.col = math.min(s.col, #s.lines[s.row]); update_scroll()
        elseif ev.code == 208 and s.row < #s.lines then
          s.row = s.row + 1
          s.col = math.min(s.col, #s.lines[s.row]); update_scroll()
        elseif ev.code == 203 and s.col > 0 then
          s.col = s.col - 1
        elseif ev.code == 205 and s.col < #cur_line then
          s.col = s.col + 1
        elseif ev.code == 199 then
          s.col = 0
        elseif ev.code == 207 then
          s.col = #cur_line
        elseif ev.code == 14 then  -- backspace
          if s.col > 0 then
            s.lines[s.row] = cur_line:sub(1, s.col - 1) .. cur_line:sub(s.col + 1)
            s.col = s.col - 1
          elseif s.row > 1 then
            local prev = s.lines[s.row - 1]
            s.col = #prev
            s.lines[s.row - 1] = prev .. cur_line
            table.remove(s.lines, s.row)
            s.row = s.row - 1; update_scroll()
          end
        elseif ev.code == 211 then  -- delete
          if s.col < #cur_line then
            s.lines[s.row] = cur_line:sub(1, s.col) .. cur_line:sub(s.col + 2)
          elseif s.row < #s.lines then
            s.lines[s.row] = cur_line .. s.lines[s.row + 1]
            table.remove(s.lines, s.row + 1)
          end
        elseif ev.code == 28 or ev.code == 156 then  -- enter
          local left, right = cur_line:sub(1, s.col), cur_line:sub(s.col + 1)
          s.lines[s.row] = left
          table.insert(s.lines, s.row + 1, right)
          s.row = s.row + 1; s.col = 0; update_scroll()
        elseif ev.char and ev.char >= 32 then
          local glyph = ev.char < 128 and string.char(ev.char) or ucs_char(ev.char)
          s.lines[s.row] = cur_line:sub(1, s.col) .. glyph .. cur_line:sub(s.col + 1)
          s.col = s.col + 1
        else
          return false
        end
        self:invalidate(); return true
      end
      return false
    end,

    text = function(self) return table.concat(self.state.lines, "\n") end,
    set_text = function(self, t)
      self.state.lines = {}
      for line in (t or ""):gmatch("([^\n]*)\n?") do self.state.lines[#self.state.lines + 1] = line end
      if #self.state.lines == 0 then self.state.lines = { "" } end
      self.state.row, self.state.col, self.state.scroll = 1, 0, 0
      self:invalidate()
    end,
  }, props or {})
end
