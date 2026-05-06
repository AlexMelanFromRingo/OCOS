-- /apps/desktop.app/Main.lua — desktop shell.

local _, env, session = ...

local ui    = require("lib.ui")
local sched = require("k.sched")
local vfs   = require("k.vfs")
local ipc   = require("k.ipc")
local lang  = require("lib.lang")
local widget = ui.widget
local label  = ui.widgets.label
local clock  = require("lib.ui.widgets.clock")
local wall   = require("lib.ui.widgets.wallpaper")
local taskbar = ui.widgets.taskbar
local list_w = ui.widgets.list

local compositor = session and session.compositor
if not compositor then return 0 end

local theme  = compositor.theme
local sw, sh = compositor:size()
local USER   = (env and env.USER) or "root"
local HOME   = (env and env.HOME) or "/home"

-- ---- WM ------------------------------------------------------------
local wm = ui.wm.new(compositor)
session.wm = wm
session.notify = function(body, title, level)
  ipc.publish("ui.notify", { title = title or "Notice", body = body, level = level or "info" })
end

local function launch(path, app_args, app_env)
  if not vfs.exists(path) then return end
  local src = vfs.read_all(path); if not src then return end
  local fn = load(src, "=" .. path, "t", _G); if not fn then return end
  sched.spawn(function() pcall(fn, app_args or {}, app_env or env or {}, session) end,
    { name = "app:" .. path:match("([^/]+)$"), caps = { "*" } })
end

-- ---- Apps menu ------------------------------------------------------

local APPS = {
  { glyph = "📁", key = "dock.files",    path = "/apps/files.app/Main.lua"    },
  { glyph = "▦",  key = "dock.terminal", path = "/apps/terminal.app/Main.lua" },
  { glyph = "✎",  key = "dock.edit",     path = "/apps/edit.app/Main.lua"     },
  { glyph = "🛈",  key = "dock.logs",     path = "/apps/dmesg.app/Main.lua"    },
  { glyph = "🔍", key = "dock.inspect",  path = "/apps/inspect.app/Main.lua"  },
  { glyph = "⚙",  key = "dock.settings", path = "/apps/settings.app/Main.lua" },
}

local launcher_win
local function open_launcher()
  if launcher_win and launcher_win.visible then wm:focus(launcher_win); return end
  local items = {}
  for _, a in ipairs(APPS) do items[#items + 1] = a.glyph .. "  " .. lang.t(a.key) end
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

-- ---- Power menu -----------------------------------------------------

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

-- ---- Top status bar -------------------------------------------------

-- Status bar: high-contrast pill with brand on the left and clock on
-- the right. We paint with explicit colours instead of theme.surface
-- because the user reported the bar blending into the wallpaper.
local SB_BG, SB_FG = 0x1A2B40, 0xE6E6E6
local status_clock = clock({})
local status_bar = widget.new("status-bar", {
  measure = function(_, mw) return mw, 1 end,
  _layout_children = function(self)
    local b = self.bounds
    status_clock:layout(b.x + b.w - 9, b.y, 9, 1)
  end,
  draw = function(self, buffer, t)
    local b = self.bounds
    buffer:fill(b.x, b.y, b.w, b.h, " ", SB_FG, SB_BG)
    -- Brand pill (accent bg).
    local brand = " " .. (_OSVERSION or "OCOS") .. "  user: " .. USER .. " "
    for i = 1, math.min(#brand, b.w - 12) do
      buffer:set(b.x + i - 1, b.y, brand:sub(i, i), 0xFFFFFF, t.palette.accent or 0x4F8AF0)
    end
    for _, c in ipairs(self.children) do c:draw(buffer, t) end
    self.dirty = false
  end,
})
status_bar:add_child(status_clock)

-- ---- Bottom taskbar -------------------------------------------------

local tb = taskbar({
  wm = wm, user = USER,
  on_launcher = open_launcher, on_power_menu = open_power_menu,
})

-- ---- Wallpaper (per-user if available) ------------------------------

-- Default: solid desktop background. Per-user wallpaper at
-- ~/.profile/wallpaper.lua overrides it; the built-ins (stripes,
-- stars) break gpu run-coalescing into many small calls and aren't
-- worth the per-frame cost on a T3 machine, so they're opt-in only.
local wallpaper = wall({
  pattern_path = HOME .. "/.profile/wallpaper.lua",
})

-- ---- Desktop icons (~/Desktop/) -------------------------------------

local desktop_dir = HOME .. "/Desktop"
pcall(vfs.mkdir, HOME)
pcall(vfs.mkdir, desktop_dir)
local icons_w = ui.widgets.icons({ path = desktop_dir, session = session })
ipc.subscribe("ui.desktop.refresh", function() icons_w:refresh() end)

-- ---- Toast notifications --------------------------------------------

local toast_w = ui.widgets.toast({})

-- ---- Root composition -----------------------------------------------

local root = widget.new("desktop-root", {
  measure = function(_, w, h) return w, h end,
  _layout_children = function(self)
    local b = self.bounds
    self.children[1]:layout(b.x, b.y, b.w, b.h)              -- wallpaper full
    self.children[2]:layout(b.x, b.y, b.w, 1)                -- status bar top
    self.children[3]:layout(b.x + 1, b.y + 2, b.w - 2, b.h - 4)  -- icons (just under status bar, leave taskbar)
    self.children[4]:layout(b.x, b.y + 1, b.w, b.h - 2)      -- workspace (windows)
    self.children[5]:layout(b.x, b.y + b.h - 1, b.w, 1)      -- taskbar bottom
    self.children[6]:layout(b.x, b.y, b.w, b.h)              -- toast overlay
  end,
  draw = function(self, buf, t)
    for _, c in ipairs(self.children) do c:draw(buf, t) end
    self.dirty = false
  end,
})
root:add_child(wallpaper)
root:add_child(status_bar)
root:add_child(icons_w)
root:add_child(wm.root)
root:add_child(tb)
root:add_child(toast_w)

compositor:add(root)
if compositor.attach_wm then compositor:attach_wm(wm) end
compositor:invalidate()

-- One-second tick: refresh the bits that show time. clock.lua's own
-- ticker already invalidates status_clock once a second, so we only
-- need to nudge the taskbar (its mini-clock format hasn't subscribed
-- to clock.tick yet). compositor:invalidate just flips self.dirty —
-- it no longer wipes the prev cell arrays, so the diff-flush still
-- emits only the seconds-digit cells that actually changed.
sched.spawn(function()
  while true do
    sched.sleep(1)
    tb:invalidate()
    computer.pushSignal("__ui_tick")
  end
end, { name = "desktop-tick", caps = { "*" } })

-- Force a full repaint when the active locale changes so the user
-- immediately sees the new strings in launcher, taskbar and settings.
ipc.subscribe("lang.changed", function() compositor:invalidate() end)

-- Live wallpaper swap: Settings writes ~/.profile/wallpaper.lua and
-- publishes this signal; we ask the widget to re-read the file and
-- mark itself dirty so the next render picks up the new pattern.
ipc.subscribe("ui.wallpaper.changed", function()
  if wallpaper.reload then wallpaper:reload() end
  compositor:full_repaint()
end)

ipc.publish("ui.notify", { title = "Welcome", body = "OCOS desktop loaded for " .. USER })

return 0
