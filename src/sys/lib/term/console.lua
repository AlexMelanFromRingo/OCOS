-- /sys/lib/term/console.lua — single-screen text terminal.
--
-- Owns the cursor, handles line wrapping, scrolling, colours, and a
-- blocking line editor that consumes keyboard events from the IPC bus.
--
-- Public API:
--   console.init()                                set up cursor + colours
--   console.write(s)                              write text at the cursor
--   console.writeln(s?)                           write + newline
--   console.clear()                               clear and home cursor
--   console.set_fg(rgb), console.set_bg(rgb)
--   console.fg(), console.bg()                    current colour
--   console.cursor() -> x, y                      current cursor
--   console.set_cursor(x, y)
--   console.size() -> w, h                        usable area
--   console.read_line(prompt?, opts?) -> string   blocks for ENTER
--
-- read_line opts:
--   history       — table with {entries, pos} or a provider with
--                   :record(line) / :all() — controls Up/Down recall.
--                   A simple list at history.entries is also accepted.
--   complete      — callback(prefix, line, cursor) -> {strings} for Tab.
--                   Returns either a single string (autofilled directly)
--                   or a list (common-prefix autofill + multi-line print).
--   on_interrupt  — callback() -> "reset" | "abort". Default "abort"
--                   (read_line returns nil). The shell uses "reset" so
--                   Ctrl-C just clears the current line.

local M = {}

local sched   = require("k.sched")
local gpu     = require("drv.gpu")
local keymap  = require("lib.term.keymap")

local cur_x, cur_y
local fg, bg

local function size() return gpu.size() end

local function scroll_up(n)
  n = n or 1
  local w, h = size()
  if not w or w <= 0 or h <= 0 then return end
  if n >= h then gpu.fill(1, 1, w, h, " "); cur_y = 1; return end
  gpu.copy(1, 1 + n, w, h - n, 0, -n)
  gpu.fill(1, h - n + 1, w, n, " ")
  cur_y = cur_y - n
end

local function newline()
  cur_x = 1
  cur_y = cur_y + 1
  local _, h = size()
  if h and cur_y > h then scroll_up(cur_y - h) end
end

function M.init()
  fg, bg = 0xCCCCCC, 0x000000
  cur_x, cur_y = 1, 1
  gpu.set_fg(fg); gpu.set_bg(bg)
  gpu.clear()
end

function M.size() return size() end
function M.fg() return fg end
function M.bg() return bg end
function M.set_fg(c) fg = c; gpu.set_fg(c) end
function M.set_bg(c) bg = c; gpu.set_bg(c) end
function M.cursor() return cur_x, cur_y end
function M.set_cursor(x, y) cur_x, cur_y = x, y end

function M.clear() gpu.clear(); cur_x, cur_y = 1, 1 end

function M.write(s)
  s = tostring(s)
  local w, h = size()
  if not w or w <= 0 or not h or h <= 0 then return end
  for piece in s:gmatch("[^\n]*\n?") do
    if piece == "" then break end
    local has_nl = piece:sub(-1) == "\n"
    local body = has_nl and piece:sub(1, -2) or piece
    while #body > 0 do
      local space = w - cur_x + 1
      if space <= 0 then
        newline()
        space = w - cur_x + 1
        if space <= 0 then break end
      end
      local chunk = body:sub(1, space)
      gpu.set(cur_x, cur_y, chunk)
      cur_x = cur_x + #chunk
      body = body:sub(#chunk + 1)
    end
    if has_nl then newline() end
  end
end

function M.writeln(s) M.write((s or "") .. "\n") end

-- ---- line editor --------------------------------------------------------

local default_history = { entries = {}, pos = nil }

local function history_record(h, line)
  if not line or line == "" then return end
  if h.record then return h:record(line) end
  local list = h.entries
  if list[#list] == line then return end
  list[#list + 1] = line
  if h.limit and #list > h.limit then
    table.remove(list, 1)
  end
end

local function history_list(h)
  if h.all then return h:all() end
  return h.entries or {}
end

local function key_filter(name)
  return name == "key_down" or name == "clipboard"
end

-- Draws a one-cell inverse caret at (x, y) on top of `under_char`. Returns
-- a function that erases the caret (restores `under_char` with the normal
-- palette) — call it before any further painting.
local function draw_caret(x, y, under_char)
  local nfg = gpu.get_fg() or fg
  local nbg = gpu.get_bg() or bg
  gpu.set_fg(nbg); gpu.set_bg(nfg)
  gpu.set(x, y, under_char or " ")
  gpu.set_fg(nfg); gpu.set_bg(nbg)
  return function()
    gpu.set(x, y, under_char or " ")
  end
end

-- Splits the prefix preceding `cur` into the [last word boundary, cur] slice
-- where a "word" runs over alphanumerics + '_' + '-' + '/' + '.'.
local function word_back(buf, cur)
  if cur == 0 then return 0 end
  local i = cur
  while i > 0 and (buf[i] == " " or buf[i] == "\t") do i = i - 1 end
  while i > 0 and not (buf[i] == " " or buf[i] == "\t") do i = i - 1 end
  return i
end

local function common_prefix(strings)
  if #strings == 0 then return "" end
  local first = strings[1]
  local n = #first
  for i = 2, #strings do
    local s = strings[i]
    local m = 0
    while m < n and m < #s and s:sub(m + 1, m + 1) == first:sub(m + 1, m + 1) do
      m = m + 1
    end
    n = m
    if n == 0 then return "" end
  end
  return first:sub(1, n)
end

function M.read_line(prompt, opts)
  opts = opts or {}
  prompt = prompt or ""
  M.write(prompt)
  local _, sy = M.cursor()
  local prompt_len = M.cursor() - 1
  local buf, cur = {}, 0
  local hist = opts.history or default_history
  local hist_list = history_list(hist)
  local hist_pos
  local interrupt_action = opts.on_interrupt or function() return "abort" end
  local clear_caret

  local function field_width()
    local w = size() or 1
    return math.max(1, w - prompt_len)
  end

  local function repaint()
    if clear_caret then clear_caret(); clear_caret = nil end
    local w = field_width()
    gpu.fill(prompt_len + 1, sy, w, 1, " ")
    local s = table.concat(buf)
    if #s > w then s = s:sub(#s - w + 1) end
    gpu.set(prompt_len + 1, sy, s)
    cur_x = prompt_len + 1 + math.min(cur, w - 1)
    cur_y = sy
    local under = buf[cur + 1] or " "
    clear_caret = draw_caret(cur_x, cur_y, under)
  end

  local function set_buf(s)
    buf = {}
    for i = 1, #s do buf[i] = s:sub(i, i) end
    cur = #buf
  end

  local function finish(line)
    if clear_caret then clear_caret(); clear_caret = nil end
    M.set_cursor(prompt_len + 1 + #buf, sy)
    M.write("\n")
    if line and line ~= "" then history_record(hist, line) end
    return line
  end

  repaint()

  while true do
    local ev = sched.wait(key_filter)
    if ev and ev.name == "key_down" then
      local _, char, code = ev.args[1], ev.args[2], ev.args[3]
      local action = keymap.action(code, char)
      if action == "enter" then
        return finish(table.concat(buf))
      elseif action == "backspace" then
        if cur > 0 then table.remove(buf, cur); cur = cur - 1; repaint() end
      elseif action == "delete" then
        if cur < #buf then table.remove(buf, cur + 1); repaint() end
      elseif action == "delete_word_back" then
        local start = word_back(buf, cur)
        if start < cur then
          for _ = 1, cur - start do table.remove(buf, start + 1) end
          cur = start; repaint()
        end
      elseif action == "clear_line" then
        if cur > 0 then
          for _ = 1, cur do table.remove(buf, 1) end
          cur = 0; repaint()
        end
      elseif action == "kill_to_eol" then
        if cur < #buf then
          for _ = #buf, cur + 1, -1 do buf[_] = nil end
          repaint()
        end
      elseif action == "left" then
        if cur > 0 then cur = cur - 1; repaint() end
      elseif action == "right" then
        if cur < #buf then cur = cur + 1; repaint() end
      elseif action == "home" then
        if cur ~= 0 then cur = 0; repaint() end
      elseif action == "end" then
        if cur ~= #buf then cur = #buf; repaint() end
      elseif action == "redraw" then
        M.clear(); M.write(prompt); sy = ({M.cursor()})[2]; repaint()
      elseif action == "up" or action == "down" then
        local n = #hist_list
        if n > 0 then
          hist_pos = hist_pos or n + 1
          hist_pos = action == "up"
            and math.max(1, hist_pos - 1)
            or  math.min(n + 1, hist_pos + 1)
          set_buf(hist_list[hist_pos] or "")
          repaint()
        end
      elseif action == "tab" then
        if opts.complete then
          local prefix = table.concat(buf, "", 1, cur)
          local matches = opts.complete(prefix, table.concat(buf), cur)
          if type(matches) == "string" then
            set_buf(matches .. table.concat(buf, "", cur + 1)); cur = #matches
            repaint()
          elseif type(matches) == "table" and #matches > 0 then
            local cp = common_prefix(matches)
            if #cp > #prefix then
              local tail = table.concat(buf, "", cur + 1)
              set_buf(cp .. tail); cur = #cp
              repaint()
            elseif #matches > 1 then
              if clear_caret then clear_caret(); clear_caret = nil end
              M.set_cursor(prompt_len + 1 + #buf, sy)
              M.write("\n")
              for i = 1, #matches do M.write(matches[i] .. "  ") end
              M.write("\n")
              M.write(prompt)
              sy = ({M.cursor()})[2]
              repaint()
            end
          end
        end
      elseif action == "interrupt" then
        local what = interrupt_action()
        if what == "reset" then
          if clear_caret then clear_caret(); clear_caret = nil end
          M.set_cursor(prompt_len + 1 + #buf, sy)
          M.write("^C\n"); M.write(prompt)
          sy = ({M.cursor()})[2]
          buf, cur = {}, 0; hist_pos = nil
          repaint()
        else
          if clear_caret then clear_caret(); clear_caret = nil end
          M.write("\n")
          return nil
        end
      elseif action == "eof" then
        if #buf == 0 then
          if clear_caret then clear_caret(); clear_caret = nil end
          M.write("\n"); return nil
        end
      elseif char and char >= 32 and char < 127 then
        cur = cur + 1
        table.insert(buf, cur, string.char(char))
        repaint()
      elseif char and char >= 128 then
        local u = _G.unicode
        local glyph = u and u.char and u.char(char) or nil
        if glyph then
          cur = cur + 1
          table.insert(buf, cur, glyph)
          repaint()
        end
      end
    elseif ev and ev.name == "clipboard" then
      local _, text = ev.args[1], ev.args[2]
      if text then
        local first_nl = text:find("\n", 1, true)
        local before_nl = first_nl and text:sub(1, first_nl - 1) or text
        for i = 1, #before_nl do
          cur = cur + 1
          table.insert(buf, cur, before_nl:sub(i, i))
        end
        repaint()
        if first_nl then
          return finish(table.concat(buf))
        end
      end
    end
  end
end

function M.history() return default_history.entries end

return M
