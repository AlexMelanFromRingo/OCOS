-- /apps/stopwatch.app/Main.lua — sample GUI app.
--
-- Demonstrates a tiny end-to-end OCOS app: window with body widget,
-- background tick coroutine driving a clock display, three buttons
-- wired to local state. Used as the "hello world" for `pkg install`
-- — the matching manifest.cfg + .ocpkg recipe lives next to this
-- file.

local _, env, session = ...
local ui    = require("lib.ui")
local sched = require("k.sched")
local widget = ui.widget
local button = ui.widgets.button

if not (session and session.compositor and session.wm) then return 1 end

local state = {
  running    = false,
  base       = 0,                                  -- accumulated seconds
  start_at   = 0,                                  -- uptime when started
  alive      = true,
}

local function elapsed()
  if state.running then
    return state.base + (computer.uptime() - state.start_at)
  end
  return state.base
end

local function fmt(t)
  if t < 0 then t = 0 end
  local h = math.floor(t / 3600)
  local m = math.floor(t / 60) % 60
  local s = t % 60
  return string.format("%02d:%02d:%05.2f", h, m, s)
end

local display = widget.new("stopwatch-display", {
  measure = function(_, mw, mh) return mw, mh end,
  draw = function(self, buf, theme)
    local b = self.bounds
    buf:fill(b.x, b.y, b.w, b.h, " ", theme.palette.fg, theme.palette.bg)
    local text = fmt(elapsed())
    local y = b.y + math.max(0, (b.h - 3) // 2)
    local fg = state.running
      and (theme.palette.accent or 0x4F8AF0)
      or  (theme.palette.fg or 0xE6E6E6)
    -- Centred, big-ish: spaced glyphs to read on a small screen.
    local x = b.x + math.max(0, (b.w - #text) // 2)
    for i = 1, #text do
      buf:set(x + i - 1, y, text:sub(i, i), fg, theme.palette.bg)
    end
    self.dirty = false
  end,
})

local function repaint()
  display:invalidate()
  computer.pushSignal("__ui_tick")
end

local btn_start = button({
  text = "Start", width = 8,
  on_click = function(self)
    if state.running then return end
    state.start_at = computer.uptime()
    state.running  = true
    self.props.text = "Stop"
    repaint()
  end,
})

local btn_stop = button({
  text = "Stop", width = 8,
  on_click = function()
    if not state.running then return end
    state.base = state.base + (computer.uptime() - state.start_at)
    state.running = false
    btn_start.props.text = "Start"
    repaint()
  end,
})

local btn_reset = button({
  text = "Reset", width = 8,
  on_click = function()
    state.running = false
    state.base = 0
    btn_start.props.text = "Start"
    repaint()
  end,
})

local body = widget.new("stopwatch-body", {
  measure = function(_, mw, mh) return mw, mh end,
  _layout_children = function(self)
    local b = self.bounds
    display:layout(b.x, b.y, b.w, b.h - 2)
    btn_start:layout(b.x + 2,  b.y + b.h - 1, 8, 1)
    btn_stop:layout (b.x + 12, b.y + b.h - 1, 8, 1)
    btn_reset:layout(b.x + 22, b.y + b.h - 1, 8, 1)
  end,
  draw = function(self, buf, t)
    local b = self.bounds
    buf:fill(b.x, b.y, b.w, b.h, " ", t.palette.fg, t.palette.bg)
    for _, c in ipairs(self.children) do c:draw(buf, t) end
    self.dirty = false
  end,
})
body:add_child(display)
body:add_child(btn_start)
body:add_child(btn_stop)
body:add_child(btn_reset)

local win = session.wm:open{
  title = "Stopwatch", body = body, w = 36, h = 8, x = 6, y = 4,
  on_close = function() state.alive = false end,
}

-- Drive the display while the watch is running. We stop the loop on
-- window close so it doesn't keep ticking after the app is gone.
sched.spawn(function()
  while state.alive do
    sched.sleep(0.1)
    if state.running then repaint() end
  end
end, { name = "stopwatch-tick", caps = { "*" } })

return 0
