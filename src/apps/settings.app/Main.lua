-- /apps/settings.app/Main.lua — system preferences.
local _, _, session = ...
local ui      = require("lib.ui")
local theme_m = require("lib.ui.theme")
local vfs     = require("k.vfs")

if not (session and session.compositor) then return 1 end
local compositor = session.compositor

local themes = {}
for _, n in ipairs(vfs.list("/etc/themes") or {}) do
  if n:sub(-4) == ".lua" then themes[#themes + 1] = n:sub(1, -5) end
end
table.sort(themes)

local theme_list = ui.widgets.list({
  items   = themes,
  width   = 30, height = #themes,
  selected = 1,
  on_activate = function(_, name)
    local t, err = theme_m.load(name)
    if t then
      theme_m.set(t)
      compositor:set_theme(t)
      compositor:invalidate()
    else
      if session.notify then session.notify("settings: " .. tostring(err)) end
    end
  end,
})
theme_list.state.focused = true

local body = ui.layout.col({
  gap = 1,
  children = {
    ui.widgets.label({ text = " Theme (Enter to apply):" }),
    theme_list,
  },
})

local win = ui.widgets.window({
  title = "Settings", w = 34, h = #themes + 5,
  body = body,
  on_close = function(self) self.visible = false; self:invalidate() end,
})
win:layout(10, 4, 34, #themes + 5)
compositor:add(win)
compositor:invalidate()
return 0
