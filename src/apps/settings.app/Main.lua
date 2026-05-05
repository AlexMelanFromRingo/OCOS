-- /apps/settings.app/Main.lua — system preferences (tabbed).
--
-- Tabs: Appearance · Language · Time · About. Side strip lets the
-- user switch; the main pane swaps content. Selecting any item in
-- a list applies it immediately (no "OK" button needed).

local _, env, session = ...
local ui      = require("lib.ui")
local theme_m = require("lib.ui.theme")
local lang    = require("lib.lang")
local vfs     = require("k.vfs")
local widget  = ui.widget
local label_w = ui.widgets.label
local list_w  = ui.widgets.list

if not (session and session.compositor and session.wm) then return 1 end
local compositor = session.compositor

-- ---- panes -----------------------------------------------------------

local function appearance_pane()
  local themes = {}
  for _, n in ipairs(vfs.list("/etc/themes") or {}) do
    if n:sub(-4) == ".lua" then themes[#themes + 1] = n:sub(1, -5) end
  end
  table.sort(themes)
  local list = list_w({
    items = themes, width = 24, height = math.max(#themes, 4),
    on_select = function(_, name)
      local t = theme_m.load(name)
      if t then theme_m.set(t); compositor:set_theme(t); compositor:invalidate() end
    end,
  })
  local pane = widget.new("appearance", {
    measure = function(_, mw, mh) return mw, mh end,
    _layout_children = function(self)
      local b = self.bounds
      self.children[1]:layout(b.x, b.y,    b.w, 1)
      self.children[2]:layout(b.x, b.y + 1, b.w, b.h - 1)
    end,
    draw = function(self, buf, t)
      local b = self.bounds
      buf:fill(b.x, b.y, b.w, b.h, " ", t.palette.fg, t.palette.bg)
      for _, c in ipairs(self.children) do c:draw(buf, t) end
      self.dirty = false
    end,
  })
  pane:add_child(label_w({ text = " Theme — single click to apply:" }))
  pane:add_child(list)
  return pane
end

local function language_pane()
  local locales = {}
  for _, n in ipairs(vfs.list("/etc/locale") or {}) do
    if n:sub(-4) == ".lua" then locales[#locales + 1] = n:sub(1, -5) end
  end
  table.sort(locales)
  local current = lang.current and lang.current() or "en"
  local sel = 1
  for i, l in ipairs(locales) do if l == current then sel = i; break end end
  local list = list_w({
    items = locales, width = 16, height = math.max(#locales, 4), selected = sel,
    on_select = function(_, name)
      if lang.set then lang.set(name) end
      require("k.ipc").publish("ui.lang.changed", { locale = name })
      compositor:invalidate()
    end,
  })
  local pane = widget.new("language", {
    measure = function(_, mw, mh) return mw, mh end,
    _layout_children = function(self)
      local b = self.bounds
      self.children[1]:layout(b.x, b.y,     b.w, 1)
      self.children[2]:layout(b.x, b.y + 1, b.w, b.h - 1)
    end,
    draw = function(self, buf, t)
      local b = self.bounds
      buf:fill(b.x, b.y, b.w, b.h, " ", t.palette.fg, t.palette.bg)
      for _, c in ipairs(self.children) do c:draw(buf, t) end
      self.dirty = false
    end,
  })
  pane:add_child(label_w({ text = " Language — current: " .. current }))
  pane:add_child(list)
  return pane
end

local function time_pane()
  local function time_now()
    local t = math.floor((computer.realTime and computer.realTime()) or computer.uptime())
    return string.format("%02d:%02d:%02d", math.floor(t/3600)%24, math.floor(t/60)%60, t%60)
  end
  return widget.new("time", {
    measure = function(_, mw, mh) return mw, mh end,
    draw = function(self, buf, t)
      local b = self.bounds
      buf:fill(b.x, b.y, b.w, b.h, " ", t.palette.fg, t.palette.bg)
      local clock_str = time_now()
      local lines = {
        " System time",
        " ───────────",
        " " .. clock_str,
        "",
        " (timezone offsets stored in /etc/time.cfg are honoured by the",
        " clock widget; setting them from the GUI is not yet implemented.)",
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

local function about_pane()
  return widget.new("about", {
    measure = function(_, mw, mh) return mw, mh end,
    draw = function(self, buf, t)
      local b = self.bounds
      buf:fill(b.x, b.y, b.w, b.h, " ", t.palette.fg, t.palette.bg)
      local lines = {
        " " .. (_OSVERSION or "OCOS"),
        " ──────────────────",
        " A modern Lua OS for the OpenComputers Minecraft mod.",
        "",
        " User: " .. ((env and env.USER) or "root"),
        " Boot: " .. tostring(_OCOS and _OCOS.boot_addr and _OCOS.boot_addr:sub(1, 8) or "?"),
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

-- ---- shell with tab strip ------------------------------------------

local TABS = { "Appearance", "Language", "Time", "About" }
local PANE_FNS = { appearance_pane, language_pane, time_pane, about_pane }
local active = 1
local pane_widget = PANE_FNS[active]()
local body                                                    -- forward decl

local tabs_lst = list_w({
  items = TABS, width = 14, height = #TABS, selected = active,
  on_select = function(_, _, idx)
    active = idx
    body:remove_children()
    body:add_child(tabs_lst)
    pane_widget = PANE_FNS[idx]()
    body:add_child(pane_widget)
    body:layout(body.bounds.x, body.bounds.y, body.bounds.w, body.bounds.h)
    body:invalidate()
  end,
})

body = widget.new("settings-body", {
  measure = function(_, mw, mh) return mw, mh end,
  _layout_children = function(self)
    local b = self.bounds
    self.children[1]:layout(b.x, b.y, 14, b.h)
    if self.children[2] then self.children[2]:layout(b.x + 15, b.y, b.w - 15, b.h) end
  end,
  draw = function(self, buf, t)
    local b = self.bounds
    buf:fill(b.x, b.y, b.w, b.h, " ", t.palette.fg, t.palette.bg)
    -- Vertical separator
    for y = b.y, b.y + b.h - 1 do
      buf:set(b.x + 14, y, "│", t.palette.muted or 0x666666, t.palette.bg)
    end
    for _, c in ipairs(self.children) do c:draw(buf, t) end
    self.dirty = false
  end,
})
body:add_child(tabs_lst)
body:add_child(pane_widget)

session.wm:open{
  title = "Settings", body = body, w = 56, h = 14, x = 6, y = 4,
}
return 0
