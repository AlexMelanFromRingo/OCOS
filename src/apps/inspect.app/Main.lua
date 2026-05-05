-- /apps/inspect.app/Main.lua — process and capability inspector.
local _, _, session = ...
local ui    = require("lib.ui")
local proc  = require("k.proc")
local ipc   = require("k.ipc")
local sched = require("k.sched")

if not (session and session.compositor) then return 1 end
local compositor = session.compositor

local function snapshot()
  local lines = { string.format("%-4s %-10s %-12s %s", "PID", "STATUS", "NAME", "CMDLINE") }
  for _, p in ipairs(proc.list()) do
    lines[#lines + 1] = string.format("%-4d %-10s %-12s %s",
      p.id, p.status, p.name, p.cmdline or p.name)
  end
  return lines
end

local list = ui.widgets.list({
  items = snapshot(),
  width = 70,
  height = 18,
})
local win = ui.widgets.window({
  title = "Processes", w = 74, h = 22,
  body = list,
  on_close = function(self) self.visible = false; self:invalidate() end,
})
win:layout(5, 5, 74, 22)
compositor:add(win)
compositor:invalidate()

-- Refresh every second.
sched.spawn(function()
  while win.visible ~= false do
    sched.sleep(1)
    list.props.items = snapshot()
    list:invalidate()
    computer.pushSignal("__ui_tick")
  end
end, { name = "inspect-refresh", caps = { "*" } })

return 0
