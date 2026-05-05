-- /apps/desktop.app/Main.lua — desktop shell.
--
-- Receives a compositor session from /sys/svc/uid. Adds a wallpaper, top
-- status bar, and bottom dock with launchers for the built-in apps.

local _, _, session = ...

local ui      = require("lib.ui")
local sched   = require("k.sched")
local vfs     = require("k.vfs")
local lang    = require("lib.lang")
local label   = ui.widgets.label
local clock   = require("lib.ui.widgets.clock")
local dock    = require("lib.ui.widgets.dock")
local wall    = require("lib.ui.widgets.wallpaper")
local widget  = ui.widget

local compositor = session and session.compositor
if not compositor then return 0 end

local theme = compositor.theme

-- ---- launch helper -----------------------------------------------------
-- Apps are simple Lua chunks loaded with the same _G the desktop sees, so
-- a launch is just `load(src) + call`. We pass the live session so the
-- spawned app can attach widgets to our compositor.
local function launch(path)
  if not vfs.exists(path) then
    if session.notify then session.notify("No such app: " .. path) end
    return
  end
  local src, err = vfs.read_all(path)
  if not src then return end
  local fn, lerr = load(src, "=" .. path, "t", _G)
  if not fn then return end
  sched.spawn(function() pcall(fn, {}, {}, session) end,
    { name = "app:" .. path, caps = { "*" } })
end

-- ---- top status bar ----------------------------------------------------
local title = label({
  text = " " .. (_OSVERSION or "OCOS"),
  fg   = (theme.taskbar and theme.taskbar.fg) or theme.palette.fg,
  bg   = (theme.taskbar and theme.taskbar.bg) or theme.palette.surface,
})
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

-- ---- dock --------------------------------------------------------------
local launcher = dock({ items = {
  { label = lang.t("dock.files"),    on_click = function() launch("/apps/files.app/Main.lua")    end },
  { label = lang.t("dock.terminal"), on_click = function() launch("/apps/terminal.app/Main.lua") end },
  { label = lang.t("dock.edit"),     on_click = function() launch("/apps/edit.app/Main.lua")     end },
  { label = lang.t("dock.logs"),     on_click = function() launch("/apps/dmesg.app/Main.lua")    end },
  { label = lang.t("dock.inspect"),  on_click = function() launch("/apps/inspect.app/Main.lua")  end },
  { label = lang.t("dock.settings"), on_click = function() launch("/apps/settings.app/Main.lua") end },
} })

-- ---- root composition --------------------------------------------------
local desktop_root = widget.new("desktop-root", {
  measure = function(_, w, h) return w, h end,
  _layout_children = function(self)
    local b = self.bounds
    self.children[1]:layout(b.x, b.y, b.w, b.h)
    self.children[2]:layout(b.x, b.y, b.w, 1)
    self.children[3]:layout(b.x, b.y + b.h - 1, b.w, 1)
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
