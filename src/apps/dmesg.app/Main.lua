-- /apps/dmesg.app/Main.lua — viewer for the kernel log ring buffer.
local _, _, session = ...
local ui  = require("lib.ui")
local log = require("k.log")
local ipc = require("k.ipc")

if not (session and session.compositor) then return 1 end
local compositor = session.compositor

local function format(entry)
  return string.format("[%8.3f] %-6s %-10s  %s",
    entry.time, entry.level:upper(), entry.tag, entry.msg)
end

local items = {}
for _, e in ipairs(log.entries()) do items[#items + 1] = format(e) end

local list = ui.widgets.list({
  items = items,
  height = 18,
  width  = 70,
})
local win = ui.widgets.window({
  title = "Logs (live)", w = 74, h = 22,
  body = list,
  on_close = function(self) self.visible = false; self:invalidate() end,
})
win:layout(3, 3, 74, 22)
compositor:add(win)
compositor:invalidate()

-- Live tap: append new entries as they arrive.
log.subscribe(nil, function(e)
  items[#items + 1] = format(e)
  if #items > 1000 then table.remove(items, 1) end
  list.state.scroll = math.max(0, #items - list.bounds.h)
  list:invalidate()
  computer.pushSignal("__ui_tick")
end)

return 0
