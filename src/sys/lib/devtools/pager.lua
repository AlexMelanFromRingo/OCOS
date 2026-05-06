-- /sys/lib/devtools/pager.lua — interactive line-paginator.
--
-- Used by /bin/less and /bin/help. Renders one screenful at a time onto
-- the current GPU; consumes key_down (j/k/space/etc.) and `scroll` (mouse
-- wheel) events through sched.wait. Returns when the user presses q/Esc.

local M = {}

local sched   = require("k.sched")
local console = require("lib.term.console")
local gpu     = require("drv.gpu")
local keymap  = require("lib.term.keymap")

local function wrap(text, width)
  local out = {}
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    if raw == "" then out[#out + 1] = ""
    else
      local i = 1
      while i <= #raw do
        out[#out + 1] = raw:sub(i, i + width - 1)
        i = i + width
      end
    end
  end
  return out
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

function M.show(text, opts)
  opts = opts or {}
  -- If we're running through a pipe (e.g., the GUI terminal hosts the
  -- shell and stdout is a stream, not a TTY), don't paint to the gpu —
  -- that would land the page outside the terminal window. Just dump
  -- text to stdout and let the host scroll. The TTY path keeps the
  -- interactive `q / j / k / Space` viewer.
  --
  -- The per-process `io` library lives in the caller's chunk env, not
  -- in `_G`, so pager modules cannot reach it directly. Callers pass
  -- `opts.io` (their own `io` table) to give us a handle.
  local pio = opts.io or rawget(_G, "io")
  local out = pio and pio.output and pio.output() or nil
  if out and not out._isatty then
    if out.write then out:write(text) end
    if text and not text:match("\n$") then out:write("\n") end
    return 0
  end

  local sw, sh = gpu.size()
  sw, sh = sw or 80, sh or 25
  local lines = wrap(text or "", sw)
  if #lines <= sh - 1 and not opts.always then
    console.write(text)
    if not text:match("\n$") then console.writeln("") end
    return 0
  end

  local view_h = sh - 1
  local off = 0
  local title = opts.title

  local function render()
    gpu.fill(1, 1, sw, sh, " ")
    local n = math.min(view_h, #lines - off)
    for i = 1, n do gpu.set(1, i, lines[off + i]) end
    local fg, bg = gpu.get_fg(), gpu.get_bg()
    gpu.set_fg(bg); gpu.set_bg(fg)
    local last = math.min(off + view_h, #lines)
    local pct  = #lines == 0 and 100 or math.floor(100 * last / #lines)
    local bar  = string.format(" %s  lines %d-%d / %d  (%d%%)  q quit  j/k scroll  Space page",
      title or "(pager)", off + 1, last, #lines, pct)
    if #bar > sw then bar = bar:sub(1, sw) else bar = bar .. string.rep(" ", sw - #bar) end
    gpu.set(1, sh, bar)
    gpu.set_fg(fg); gpu.set_bg(bg)
  end

  render()

  while true do
    local ev = sched.wait(function(name) return name == "key_down" or name == "scroll" end)
    if ev and ev.name == "key_down" then
      local _, char, code = ev.args[1], ev.args[2], ev.args[3]
      local action = keymap.action(code, char)
      if char == 113 or action == "interrupt" then break
      elseif action == "down"  or char == 106 or action == "enter" then off = clamp(off + 1,        0, math.max(0, #lines - view_h))
      elseif action == "up"    or char == 107                       then off = clamp(off - 1,        0, math.max(0, #lines - view_h))
      elseif char  == 32       or code == 209                       then off = clamp(off + view_h,   0, math.max(0, #lines - view_h))
      elseif char  == 98       or code == 201                       then off = clamp(off - view_h,   0, math.max(0, #lines - view_h))
      elseif char  == 103                                            then off = 0
      elseif char  == 71                                             then off = math.max(0, #lines - view_h)
      end
      render()
    elseif ev and ev.name == "scroll" then
      local _, _, _, dir = ev.args[1], ev.args[2], ev.args[3], ev.args[4]
      off = clamp(off - 3 * (dir or 1), 0, math.max(0, #lines - view_h))
      render()
    end
  end

  console.clear()
  return 0
end

return M
