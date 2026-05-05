-- /apps/settings.app/Main.lua — system preferences (tabbed).
--
-- Tab strip on the left, single content pane on the right. The pane is
-- a single placeholder widget that swaps its `delegate` field; we never
-- mutate body.children mid-event-dispatch (which crashed earlier when
-- the tabs list removed itself from its parent while it was still on
-- the dispatch stack).

local _, env, session = ...
local ui      = require("lib.ui")
local theme_m = require("lib.ui.theme")
local lang    = require("lib.lang")
local vfs     = require("k.vfs")
local widget  = ui.widget
local list_w  = ui.widgets.list

if not (session and session.compositor and session.wm) then return 1 end
local compositor = session.compositor

local function appearance_pane()
  local themes = {}
  for _, n in ipairs(vfs.list("/etc/themes") or {}) do
    if n:sub(-4) == ".lua" then themes[#themes + 1] = n:sub(1, -5) end
  end
  table.sort(themes)
  return list_w({
    items = themes, width = 24, height = math.max(#themes, 4),
    on_select = function(_, name)
      local t = theme_m.load(name)
      if t then theme_m.set(t); compositor:set_theme(t); compositor:invalidate() end
    end,
  })
end

local function language_pane()
  local locales = {}
  for _, n in ipairs(vfs.list("/etc/locale") or {}) do
    if n:sub(-4) == ".lua" then locales[#locales + 1] = n:sub(1, -5) end
  end
  table.sort(locales)
  return list_w({
    items = locales, width = 16, height = math.max(#locales, 4),
    on_select = function(_, name)
      if lang.set then lang.set(name) end
      require("k.ipc").publish("ui.lang.changed", { locale = name })
      require("k.ipc").publish("ui.notify", { title = "Language", body = "Switched to " .. name })
      compositor:invalidate()
    end,
  })
end

local function time_pane()
  return widget.new("time", {
    measure = function(_, mw, mh) return mw, mh end,
    draw = function(self, buf, t)
      local b = self.bounds
      buf:fill(b.x, b.y, b.w, b.h, " ", t.palette.fg, t.palette.bg)
      local tt = math.floor((computer.realTime and computer.realTime()) or computer.uptime())
      local clock_str = string.format("%02d:%02d:%02d",
        math.floor(tt / 3600) % 24, math.floor(tt / 60) % 60, tt % 60)
      local lines = {
        " System time", " ───────────", " " .. clock_str, "",
        " Stored offsets in /etc/time.cfg are honoured",
        " by the clock widget when present.",
      }
      for i, ln in ipairs(lines) do
        for j = 1, #ln do
          buf:set(b.x + j - 1, b.y + i - 1, ln:sub(j, j),
            i <= 3 and t.palette.fg or t.palette.muted, t.palette.bg)
        end
      end
      self.dirty = false
    end,
  })
end

local function update_pane()
  return list_w({
    items = { "[ Check for updates ]", "[ Re-flash EEPROM ]" },
    width = 28, height = 4,
    on_select = function(_, _, idx)
      local ipc = require("k.ipc")
      if idx == 1 then
        ipc.publish("ui.notify", { title = "Update",
          body = "Streaming installer is TTY-only for now: /tmp/ocos.lua" })
      else
        ipc.publish("ui.notify", { title = "EEPROM",
          body = "Run installer with --flash-eeprom from TTY." })
      end
    end,
  })
end

local function about_pane()
  return widget.new("about", {
    measure = function(_, mw, mh) return mw, mh end,
    draw = function(self, buf, t)
      local b = self.bounds
      buf:fill(b.x, b.y, b.w, b.h, " ", t.palette.fg, t.palette.bg)
      local user = (env and env.USER) or "root"
      local boot = _OCOS and _OCOS.boot_addr and _OCOS.boot_addr:sub(1, 8) or "?"
      local lines = {
        " " .. (_OSVERSION or "OCOS"),
        " ──────────────────",
        " A modern Lua OS for OpenComputers.",
        "",
        " User: " .. user,
        " Boot: " .. boot,
        "",
        " github.com/AlexMelanFromRingo/OCOS",
      }
      for i, ln in ipairs(lines) do
        for j = 1, #ln do
          buf:set(b.x + j - 1, b.y + i - 1, ln:sub(j, j),
            i <= 2 and t.palette.accent or t.palette.fg, t.palette.bg)
        end
      end
      self.dirty = false
    end,
  })
end

local TABS     = { "Appearance", "Language", "Time", "Update", "About" }
local PANE_FNS = { appearance_pane, language_pane, time_pane, update_pane, about_pane }

local pane_host = widget.new("pane-host", {
  state = { delegate = nil },
  measure = function(_, mw, mh) return mw, mh end,
  draw = function(self, buf, t)
    local b = self.bounds
    buf:fill(b.x, b.y, b.w, b.h, " ", t.palette.fg, t.palette.bg)
    if self.state.delegate then
      self.state.delegate:layout(b.x, b.y, b.w, b.h)
      self.state.delegate:draw(buf, t)
    end
    self.dirty = false
  end,
  on_event = function(self, ev)
    if self.state.delegate then return self.state.delegate:on_event(ev) end
    return false
  end,
})

local function set_pane(idx)
  pane_host.state.delegate = PANE_FNS[idx]()
  pane_host:invalidate()
end
set_pane(1)

local tabs_lst = list_w({
  items = TABS, width = 14, height = #TABS, selected = 1,
  on_select = function(_, _, idx) set_pane(idx) end,
})

local body = widget.new("settings-body", {
  measure = function(_, mw, mh) return mw, mh end,
  _layout_children = function(self)
    local b = self.bounds
    self.children[1]:layout(b.x, b.y, 14, b.h)
    self.children[2]:layout(b.x + 15, b.y, b.w - 15, b.h)
  end,
  draw = function(self, buf, t)
    local b = self.bounds
    buf:fill(b.x, b.y, b.w, b.h, " ", t.palette.fg, t.palette.bg)
    for y = b.y, b.y + b.h - 1 do
      buf:set(b.x + 14, y, "│", t.palette.muted or 0x666666, t.palette.bg)
    end
    for _, c in ipairs(self.children) do c:draw(buf, t) end
    self.dirty = false
  end,
})
body:add_child(tabs_lst)
body:add_child(pane_host)

session.wm:open{
  title = "Settings", body = body, w = 56, h = 14, x = 6, y = 4,
}
return 0
