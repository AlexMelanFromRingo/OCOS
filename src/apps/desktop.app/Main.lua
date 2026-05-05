-- /apps/desktop.app/Main.lua — desktop shell.
--
-- Receives a ready-to-use `compositor` from /sys/svc/uid via the global
-- "ui.session" channel. Adds a wallpaper, top status bar, and bottom dock.
-- Apps launched from the dock open windows on the same compositor.

local args, env, session = ...

local ui      = require("lib.ui")
local theme_m = require("lib.ui.theme")
local label   = ui.widgets.label
local clock   = require("lib.ui.widgets.clock")
local dock    = require("lib.ui.widgets.dock")
local wall    = require("lib.ui.widgets.wallpaper")
local layout  = ui.layout
local widget  = ui.widget

local compositor = session and session.compositor
if not compositor then return 0 end                -- launched without a session: no-op

local theme = compositor.theme

-- Top status bar: "OCOS X.Y.Z" on the left, clock on the right.
local cw, ch = compositor:size()
local title = label({ text = " " .. (_OSVERSION or "OCOS"),
                      fg = (theme.taskbar and theme.taskbar.fg) or theme.palette.fg,
                      bg = (theme.taskbar and theme.taskbar.bg) or theme.palette.surface })
local status_clock = clock({})
local status_bar = widget.new("status-bar", {
  measure = function(_, max_w) return max_w, 1 end,
  _layout_children = function(self)
    local b = self.bounds
    title:layout(b.x, b.y, b.w - 9, 1)
    status_clock:layout(b.x + b.w - 8, b.y, 8, 1)
  end,
  draw = function(self, buffer, t)
    local b = self.bounds
    local bg = (t.taskbar and t.taskbar.bg) or t.palette.surface
    buffer:fill(b.x, b.y, b.w, b.h, " ", t.palette.fg, bg)
    for _, c in ipairs(self.children) do c:draw(buffer, t) end
    self.dirty = false
  end,
})
status_bar:add_child(title)
status_bar:add_child(status_clock)

-- Empty dock — apps register via the "ui.dock.add" IPC channel as they
-- become available. The compositor already broadcasts launches.
local launcher = dock({ items = {
  { label = "About", on_click = function()
    local win = ui.widgets.window({
      title = "About OCOS",
      w = 30, h = 5,
      body = label({ text = " " .. (_OSVERSION or "OCOS") .. " — running.", align = "start" }),
    })
    win:layout(8, 4, 30, 5)
    compositor:add(win)
    compositor:invalidate()
  end },
} })

-- Layout: wallpaper fills, status bar at top, dock at bottom, content area
-- between them is left empty for windows.
local desktop_root = widget.new("desktop-root", {
  measure = function(_, w, h) return w, h end,
  _layout_children = function(self)
    local b = self.bounds
    self.children[1]:layout(b.x, b.y, b.w, b.h)              -- wallpaper
    self.children[2]:layout(b.x, b.y, b.w, 1)                -- status bar
    self.children[3]:layout(b.x, b.y + b.h - 1, b.w, 1)      -- dock
  end,
  draw = function(self, buffer, t)
    for _, c in ipairs(self.children) do c:draw(buffer, t) end
    self.dirty = false
  end,
})
desktop_root:add_child(wall({}))
desktop_root:add_child(status_bar)
desktop_root:add_child(launcher)

compositor:add(desktop_root)
compositor:invalidate()
return 0
