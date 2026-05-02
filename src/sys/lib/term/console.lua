-- /sys/lib/term/console.lua — single-screen terminal.
-- Owns the cursor, handles wrapping, scrolling, and a blocking line editor.
-- Reads keyboard via the IPC channel `kbd.key`.

local M = {}

local sched  = require("k.sched")
local ipc    = require("k.ipc")
local gpu    = require("drv.gpu")

-- LWJGL key codes we treat as line-editor commands. Not exhaustive; M3 will
-- replace this with a proper keymap module.
local KEY = {
  enter = 28, backspace = 14, left = 203, right = 205,
  up = 200, down = 208, home = 199, end_ = 207, delete = 211, tab = 15,
}

local cur_x, cur_y                               -- 1-based, screen coords
local fg, bg

local function size() return gpu.size() end

local function scroll_up(n)
  n = n or 1
  local w, h = size()
  if not w then return end
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

function M.write(s)
  s = tostring(s)
  local w, h = size()
  if not w or w <= 0 or not h or h <= 0 then return end -- no usable display
  for piece in s:gmatch("[^\n]*\n?") do
    if piece == "" then break end
    local has_nl = piece:sub(-1) == "\n"
    local body = has_nl and piece:sub(1, -2) or piece
    while #body > 0 do
      local space = w - cur_x + 1
      if space <= 0 then
        newline()
        space = w - cur_x + 1
        if space <= 0 then break end                -- still no room — give up
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

function M.set_fg(c) fg = c; gpu.set_fg(c) end
function M.set_bg(c) bg = c; gpu.set_bg(c) end
function M.clear() gpu.clear(); cur_x, cur_y = 1, 1 end
function M.cursor() return cur_x, cur_y end

-- ---- line editor --------------------------------------------------------

local function key_filter(name)
  -- Used by sched.wait. The scheduler already published kbd.key via ipc, but
  -- the wait machinery filters by raw signal name. We listen for the raw
  -- `key_down` signal directly here for simplicity in M1.
  return name == "key_down" or name == "clipboard"
end

function M.read_line(prompt)
  if prompt then M.write(prompt) end
  local buf = {}
  local function redraw_tail()
    -- Reprint everything from cursor's logical start of buffer to here.
    -- Simple impl: just print the last char written.
  end
  while true do
    local ev = sched.wait(key_filter)
    if ev and ev.name == "key_down" then
      local _, char, code = ev.args[1], ev.args[2], ev.args[3]
      if code == KEY.enter then
        M.write("\n")
        return table.concat(buf)
      elseif code == KEY.backspace then
        if #buf > 0 then
          buf[#buf] = nil
          if cur_x > 1 then cur_x = cur_x - 1 else cur_y = cur_y - 1; cur_x = select(1, size()) end
          gpu.set(cur_x, cur_y, " ")
        end
      elseif char and char >= 32 and char < 127 then
        local c = string.char(char)
        buf[#buf + 1] = c
        M.write(c)
      elseif char and char >= 128 then
        -- Unicode codepoint via OC's `unicode` global if available.
        local u = _G.unicode
        if u and u.char then
          local c = u.char(char)
          buf[#buf + 1] = c
          M.write(c)
        end
      end
    elseif ev and ev.name == "clipboard" then
      local _, text = ev.args[1], ev.args[2]
      if text then
        for i = 1, #text do
          local c = text:sub(i, i)
          if c == "\n" then
            M.write("\n")
            return table.concat(buf)
          else
            buf[#buf + 1] = c
            M.write(c)
          end
        end
      end
    end
  end
end

return M
