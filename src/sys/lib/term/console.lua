-- /sys/lib/term/console.lua — single-screen text terminal.
--
-- Owns the cursor, handles line wrapping, scrolling, colours, and a
-- blocking line editor that consumes keyboard events from the IPC bus.
-- Maintains a 1000-line scrollback ring; the mouse wheel scrolls back
-- through it. Any keypress (or ipc "console.redraw") snaps back to live.
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

local M = {}

local sched   = require("k.sched")
local ipc     = require("k.ipc")
local gpu     = require("drv.gpu")
local keymap  = require("lib.term.keymap")

local cur_x, cur_y
local fg, bg

local SCROLL_CAP = 1000
local sb_lines                                    -- ring of completed lines (strings)
local sb_in                                       -- in-progress line buffer
local scroll_off                                  -- 0 = live; > 0 = N lines back from tail
local input_handle

local function size() return gpu.size() end

local function scroll_up_screen(n)
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
  if h and cur_y > h then scroll_up_screen(cur_y - h) end
end

local function ring_push(line)
  sb_lines[#sb_lines + 1] = line
  if #sb_lines > SCROLL_CAP then table.remove(sb_lines, 1) end
end

local function snap_to_live()
  if scroll_off == 0 then return end
  scroll_off = 0
  ipc.publish("console.redraw", {})
end

local function render_scroll()
  local w, h = size()
  if not w or w <= 0 or h <= 0 then return end
  local total = #sb_lines
  -- The "tail line" is sb_lines[total]; offset N shows lines ending at
  -- total - N. We render h rows up to that line, blank-padding above.
  local last = total - scroll_off
  local first = last - h + 1
  gpu.set_bg(bg); gpu.set_fg(fg)
  gpu.fill(1, 1, w, h, " ")
  for i = 1, h do
    local idx = first + i - 1
    if idx >= 1 and idx <= total then
      local line = sb_lines[idx] or ""
      gpu.set(1, i, line:sub(1, w))
    end
  end
  -- Status bar at the bottom while scrolled.
  if scroll_off > 0 then
    local prev_fg, prev_bg = fg, bg
    gpu.set_fg(prev_bg); gpu.set_bg(prev_fg)
    local bar = string.format(" -- scrollback %d / %d  (wheel down or any key to return) --",
      scroll_off, total)
    if #bar > w then bar = bar:sub(1, w) else bar = bar .. string.rep(" ", w - #bar) end
    gpu.set(1, h, bar)
    gpu.set_fg(prev_fg); gpu.set_bg(prev_bg)
  end
end

local function on_scroll(p)
  -- p comes from oc.signal.scroll: {addr, x, y, dir, player}
  local dir = p[4] or 0
  if dir == 0 then return end
  local total = #sb_lines
  local _, h = size()
  if not h or h <= 0 then return end
  local max_off = math.max(0, total - h + 1)
  local step = 3
  scroll_off = math.max(0, math.min(max_off, scroll_off - dir * step))
  if scroll_off > 0 then
    render_scroll()
  else
    -- Returning to live — re-render the last `h` lines from the ring AND
    -- ask any active read_line to repaint its prompt on top.
    render_scroll()
    ipc.publish("console.redraw", {})
  end
end

function M.init()
  fg, bg = 0xCCCCCC, 0x000000
  cur_x, cur_y = 1, 1
  gpu.set_fg(fg); gpu.set_bg(bg)
  gpu.clear()
  sb_lines  = sb_lines  or {}
  sb_in     = ""
  scroll_off = 0
  if not input_handle then
    input_handle = ipc.subscribe("oc.signal.scroll", on_scroll)
  end
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

  -- Ring update: split on newlines; on each \n, complete sb_in into the
  -- ring; everything else accumulates in sb_in. This keeps the ring's
  -- view of the world independent of how the GPU paints.
  local cursor = 1
  while cursor <= #s do
    local nl = s:find("\n", cursor, true)
    if nl then
      sb_in = sb_in .. s:sub(cursor, nl - 1)
      ring_push(sb_in); sb_in = ""
      cursor = nl + 1
    else
      sb_in = sb_in .. s:sub(cursor)
      cursor = #s + 1
    end
  end

  if scroll_off > 0 then return end                -- silenced while scrolled

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
  return name == "key_down" or name == "clipboard" or name == "__console_redraw"
end

local function draw_caret(x, y, under_char)
  local nfg = gpu.get_fg() or fg
  local nbg = gpu.get_bg() or bg
  gpu.set_fg(nbg); gpu.set_bg(nfg)
  gpu.set(x, y, under_char or " ")
  gpu.set_fg(nfg); gpu.set_bg(nbg)
  return function() gpu.set(x, y, under_char or " ") end
end

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
  snap_to_live()
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

  local redraw_handle
  local function cleanup()
    if redraw_handle then ipc.unsubscribe(redraw_handle); redraw_handle = nil end
    if clear_caret then clear_caret(); clear_caret = nil end
  end
  local function finish(line)
    cleanup()
    M.set_cursor(prompt_len + 1 + #buf, sy)
    M.write("\n")
    if line and line ~= "" then history_record(hist, line) end
    return line
  end

  redraw_handle = ipc.subscribe("console.redraw", function()
    computer.pushSignal("__console_redraw")
  end)

  repaint()

  while true do
    local ev = sched.wait(key_filter)
    if ev and ev.name == "__console_redraw" then
      M.clear(); M.write(prompt); sy = ({M.cursor()})[2]; clear_caret = nil; repaint()
    elseif ev and ev.name == "key_down" then
      local _, char, code = ev.args[1], ev.args[2], ev.args[3]
      if scroll_off > 0 then snap_to_live() end
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
          cleanup()
          M.write("\n")
          return nil
        end
      elseif action == "eof" then
        if #buf == 0 then
          cleanup()
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
function M.scrollback_size() return sb_lines and #sb_lines or 0 end

return M
