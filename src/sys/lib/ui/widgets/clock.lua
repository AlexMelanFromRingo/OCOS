-- /sys/lib/ui/widgets/clock.lua — live-updating clock label.
--
-- The clock invalidates itself once per second via a synthetic "__clock_tick"
-- signal so the compositor's render loop re-paints it. Keeps display in
-- sync without an animation framework.

local widget = require("lib.ui.widget")
local sched  = require("k.sched")
local ipc    = require("k.ipc")

local function format_clock()
  -- Prefer OC's wall clock when the host exposes it; older builds (e.g.
  -- the 1.12.2 community port) ship without computer.realTime, so fall
  -- back to uptime. The `and` form is necessary — `realTime() or …`
  -- still calls realTime, which errors out if the field is nil.
  local t = math.floor((computer.realTime and computer.realTime()) or computer.uptime())
  local h = math.floor(t / 3600) % 24
  local m = math.floor(t / 60) % 60
  local s = t % 60
  return string.format("%02d:%02d:%02d", h, m, s)
end

local installed_tick = false
local function ensure_tick()
  if installed_tick then return end
  installed_tick = true
  sched.spawn(function()
    while true do
      sched.sleep(1)
      ipc.publish("clock.tick", {})
      computer.pushSignal("__ui_tick")
    end
  end, { name = "clock-ticker", caps = { "*" } })
end

return function(props)
  ensure_tick()
  local w = widget.new("clock", {
    measure = function(_, max_w, max_h) return math.min(8, max_w), 1 end,
    draw = function(self, buffer, theme)
      local text = format_clock()
      local b = self.bounds
      local fg = self.props.fg or (theme.taskbar and theme.taskbar.fg) or theme.palette.fg
      local bg = self.props.bg or (theme.taskbar and theme.taskbar.bg) or theme.palette.bg
      buffer:fill(b.x, b.y, b.w, 1, " ", fg, bg)
      for i = 1, math.min(#text, b.w) do
        buffer:set(b.x + i - 1, b.y, text:sub(i, i), fg, bg)
      end
      self.dirty = false
    end,
  }, props or {})
  ipc.subscribe("clock.tick", function() w:invalidate() end)
  return w
end
