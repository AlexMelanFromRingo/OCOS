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

local M = {}

local sched   = require("k.sched")
local ipc     = require("k.ipc")
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
-- A blocking line editor that reads keyboard events from the IPC bus.
-- Supports printable characters, Home/End, Left/Right, Backspace/Delete,
-- history (Up/Down) and clipboard paste. Multi-line wrapping inside the
-- editor is not supported — long inputs simply scroll horizontally past the
-- right edge; visual selection and kill-ring are GUI-widget territory.

local history = { entries = {}, pos = nil }

local function key_filter(name)
  return name == "key_down" or name == "clipboard"
end

function M.read_line(prompt, opts)
  opts = opts or {}
  prompt = prompt or ""
  M.write(prompt)
  local _, sy = M.cursor()
  local prompt_len = M.cursor() - 1                -- column where buffer starts
  local buf, cur = {}, 0
  history.pos = nil

  local function repaint()
    local w = size()
    if not w or w <= 0 then return end
    gpu.fill(prompt_len + 1, sy, w - prompt_len, 1, " ")
    local s = table.concat(buf)
    gpu.set(prompt_len + 1, sy, s)
    cur_x = prompt_len + 1 + cur
    cur_y = sy
  end

  while true do
    local ev = sched.wait(key_filter)
    if ev and ev.name == "key_down" then
      local _, char, code = ev.args[1], ev.args[2], ev.args[3]
      local action = keymap.action(code, char)
      if action == "enter" then
        M.set_cursor(prompt_len + 1 + #buf, sy)
        M.write("\n")
        local out = table.concat(buf)
        if out ~= "" then history.entries[#history.entries + 1] = out end
        return out
      elseif action == "backspace" then
        if cur > 0 then table.remove(buf, cur); cur = cur - 1; repaint() end
      elseif action == "delete" then
        if cur < #buf then table.remove(buf, cur + 1); repaint() end
      elseif action == "left" then
        if cur > 0 then cur = cur - 1; cur_x = prompt_len + 1 + cur end
      elseif action == "right" then
        if cur < #buf then cur = cur + 1; cur_x = prompt_len + 1 + cur end
      elseif action == "home" then
        cur = 0; cur_x = prompt_len + 1
      elseif action == "end" then
        cur = #buf; cur_x = prompt_len + 1 + cur
      elseif action == "up" or action == "down" then
        local n = #history.entries
        if n > 0 then
          history.pos = history.pos or n + 1
          history.pos = action == "up"
            and math.max(1, history.pos - 1)
            or  math.min(n + 1, history.pos + 1)
          local entry = history.entries[history.pos] or ""
          buf = {}
          for i = 1, #entry do buf[i] = entry:sub(i, i) end
          cur = #buf
          repaint()
        end
      elseif action == "interrupt" then
        M.write("\n")
        return nil
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
        for ch in text:gmatch("[^\n]+") do
          for i = 1, #ch do
            cur = cur + 1
            table.insert(buf, cur, ch:sub(i, i))
          end
        end
        repaint()
        if text:find("\n", 1, true) then
          M.set_cursor(prompt_len + 1 + #buf, sy)
          M.write("\n")
          local out = table.concat(buf)
          if out ~= "" then history.entries[#history.entries + 1] = out end
          return out
        end
      end
    end
  end
end

function M.history() return history.entries end

return M
