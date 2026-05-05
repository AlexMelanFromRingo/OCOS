-- /apps/dmesg.app/Main.lua — viewer for the kernel log ring buffer.
local _, _, session = ...
local ui  = require("lib.ui")
local log = require("k.log")

if not (session and session.compositor and session.wm) then return 1 end

local function format(entry)
  return string.format("[%8.3f] %-6s %-10s  %s",
    entry.time, entry.level:upper(), entry.tag, entry.msg)
end

local items = {}
for _, e in ipairs(log.entries()) do items[#items + 1] = format(e) end

local list = ui.widgets.list({ items = items, height = 18, width = 70 })

session.wm:open{ title = "Logs (live)", body = list, w = 72, h = 18 }

log.subscribe(nil, function(e)
  items[#items + 1] = format(e)
  if #items > 1000 then table.remove(items, 1) end
  list.state.scroll = math.max(0, #items - list.bounds.h)
  list:invalidate()
  computer.pushSignal("__ui_tick")
end)

return 0
