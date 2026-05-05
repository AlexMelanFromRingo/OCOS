-- /apps/desktop.app/Main.lua — desktop shell.
--
-- Owns the wallpaper, top status bar and bottom taskbar. Spawns a
-- WM and exposes it via session.wm so launched apps put their bodies
-- into managed windows. Power menu is reachable from the taskbar.

local _, env, session = ...

local ui    = require("lib.ui")
local sched = require("k.sched")
local vfs   = require("k.vfs")
local ipc   = require("k.ipc")
local lang  = require("lib.lang")
local widget = ui.widget
local label  = ui.widgets.label
local clock  = require("lib.ui.widgets.clock")
local dock   = require("lib.ui.widgets.dock")
local wall   = require("lib.ui.widgets.wallpaper")
local taskbar = ui.widgets.taskbar
local menu   = ui.widgets.menu
local list_w = ui.widgets.list

local compositor = session and session.compositor
if not compositor then return 0 end

local theme = compositor.theme
local sw, sh = compositor:size()

-- ---- WM --------------------------------------------------------------
local wm = ui.wm.new(compositor)
session.wm = wm

local function launch(path)
  if not vfs.exists(path) then return end
  local src = vfs.read_all(path); if not src then return end
  local fn, _ = load(src, "=" .. path, "t", _G)
  if not fn then return end
  sched.spawn(function() pcall(fn, {}, env or {}, session) end,
    { name = "app:" .. path:match("([^/]+)$"), caps = { "*" } })
end

-- ---- Apps menu (popover from the taskbar's `+` button) ---------------

local APPS = {
  { glyph = "📁", label = "Files",     path = "/apps/files.app/Main.lua"    },
  { glyph = "▦",  label = "Terminal",  path = "/apps/terminal.app/Main.lua" },
  { glyph = "✎",  label = "Edit",      path = "/apps/edit.app/Main.lua"     },
  { glyph = "🛈",  label = "Logs",      path = "/apps/dmesg.app/Main.lua"    },
  { glyph = "🔍", label = "Inspect",   path = "/apps/inspect.app/Main.lua"  },
  { glyph = "⚙",  label = "Settings",  path = "/apps/settings.app/Main.lua" },
}

local launcher_win
local function open_launcher()
  if launcher_win and launcher_win.visible then wm:focus(launcher_win); return end
  local items = {}
  for _, a in ipairs(APPS) do items[#items + 1] = a.glyph .. "  " .. a.label end
  local lst = list_w({
    items = items, width = 22, height = #items,
    on_select = function(_, _, idx)
      launch(APPS[idx].path)
      if launcher_win then wm:close(launcher_win); launcher_win = nil end
    end,
  })
  launcher_win = wm:open{
    title = "Apps", w = 24, h = #items + 2, x = 2, y = sh - #items - 4,
    body = lst, minimisable = false, maximisable = false, resizable = false,
    on_close = function() launcher_win = nil end,
  }
end

-- ---- Power menu (popover from the taskbar's ⏻) -----------------------

local power_win
local function open_power_menu()
  if power_win and power_win.visible then wm:close(power_win); power_win = nil; return end
  local items = { "Lock screen", "Switch user", "Log out", "Restart", "Shut down" }
  local actions = { "lock", "switch", "logout", "reboot", "shutdown" }
  local lst = list_w({
    items = items, width = 18, height = #items,
    on_select = function(_, _, idx)
      if power_win then wm:close(power_win); power_win = nil end
      local a = actions[idx]
      if a == "shutdown" then computer.shutdown(false)
      elseif a == "reboot" then computer.shutdown(true)
      elseif a == "logout" or a == "switch" then
        ipc.publish("svc.stop.uid", true)
      elseif a == "lock" then
        launch("/apps/lock.app/Main.lua")
      end
    end,
  })
  power_win = wm:open{
    title = "Power", w = 20, h = #items + 2,
    x = sw - 22, y = sh - #items - 4,
    body = lst, minimisable = false, maximisable = false, resizable = false,
    on_close = function() power_win = nil end,
  }
end

-- ---- Status bar (top row) -------------------------------------------

local title_lbl = label({
  text = " " .. (_OSVERSION or "OCOS"),
  fg = (theme.taskbar and theme.taskbar.fg) or theme.palette.fg,
  bg = (theme.taskbar and theme.taskbar.bg) or theme.palette.surface,
})
local status_clock = clock({})
local status_bar = widget.new("status-bar", {
  measure = function(_, mw) return mw, 1 end,
  _layout_children = function(self)
    local b = self.bounds
    title_lbl:layout(b.x, b.y, b.w - 9, 1)
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
status_bar:add_child(title_lbl)
status_bar:add_child(status_clock)

-- ---- Taskbar (bottom row) -------------------------------------------

local tb = taskbar({
  wm            = wm,
  user          = (env and env.USER) or "root",
  on_launcher   = open_launcher,
  on_power_menu = open_power_menu,
})

-- ---- Root composition ------------------------------------------------

local root = widget.new("desktop-root", {
  measure = function(_, w, h) return w, h end,
  _layout_children = function(self)
    local b = self.bounds
    self.children[1]:layout(b.x, b.y, b.w, b.h)         -- wallpaper full
    self.children[2]:layout(b.x, b.y, b.w, 1)           -- status bar top
    self.children[3]:layout(b.x, b.y + 1, b.w, b.h - 2) -- workspace middle
    self.children[4]:layout(b.x, b.y + b.h - 1, b.w, 1) -- taskbar bottom
  end,
  draw = function(self, buf, t)
    for _, c in ipairs(self.children) do c:draw(buf, t) end
    self.dirty = false
  end,
})
root:add_child(wall({}))
root:add_child(status_bar)
root:add_child(wm.root)
root:add_child(tb)

compositor:add(root)
if compositor.attach_wm then compositor:attach_wm(wm) end
compositor:invalidate()

-- A second-tick refresh so the taskbar clock and chips animate.
sched.spawn(function()
  while true do sched.sleep(1); tb:invalidate(); compositor:invalidate() end
end, { name = "tb-tick", caps = { "*" } })

return 0
