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
      require("k.ipc").publish("ui.notify", {
        title = lang.t("settings.lang.title"),
        body  = string.format(lang.t("settings.notify.lang"), name) })
      compositor:invalidate()
    end,
  })
end

local TIME_CFG = "/etc/time.cfg"
local function load_time_offset()
  if not vfs.exists(TIME_CFG) then return 0 end
  local fn = load(vfs.read_all(TIME_CFG) or "", "=" .. TIME_CFG, "t", {})
  if not fn then return 0 end
  local ok, t = pcall(fn)
  return (ok and type(t) == "table" and tonumber(t.offset)) or 0
end

local function save_time_offset(off)
  return vfs.write_all(TIME_CFG, string.format("return { offset = %d }\n", off))
end

local function time_pane()
  local input = ui.widgets.input
  local offset = load_time_offset()
  local hh_field = input({ width = 4, value = "00" })
  local mm_field = input({ width = 4, value = "00" })

  -- Show current effective system time (uptime + saved offset, modulo a day).
  local function now_str()
    local raw = math.floor((computer.realTime and computer.realTime()) or computer.uptime())
    local t = (raw + offset) % 86400
    return string.format("%02d:%02d:%02d",
      math.floor(t / 3600), math.floor(t / 60) % 60, t % 60)
  end

  local apply_btn = ui.widgets.button({
    text = "Apply", width = 8,
    on_click = function()
      local h = tonumber(hh_field.state.value) or 0
      local m = tonumber(mm_field.state.value) or 0
      local raw = math.floor((computer.realTime and computer.realTime()) or computer.uptime())
      local target = ((h * 3600) + (m * 60)) % 86400
      offset = (target - (raw % 86400)) % 86400
      save_time_offset(offset)
      require("k.ipc").publish("ui.notify",
        { title = "Time", body = "Set to " .. string.format("%02d:%02d", h, m) })
    end,
  })

  return widget.new("time", {
    state = { focused = false },
    measure = function(_, mw, mh) return mw, mh end,
    _layout_children = function(self)
      local b = self.bounds
      hh_field:layout(b.x + 7,  b.y + 4, 4, 1)
      mm_field:layout(b.x + 12, b.y + 4, 4, 1)
      apply_btn:layout(b.x + 18, b.y + 4, 8, 1)
    end,
    draw = function(self, buf, t)
      local b = self.bounds
      buf:fill(b.x, b.y, b.w, b.h, " ", t.palette.fg, t.palette.bg)
      local lines = {
        " Now: " .. now_str(),
        " offset: " .. string.format("%+ds", offset),
        "",
        " Set HH : MM",
      }
      for i, ln in ipairs(lines) do
        for j = 1, math.min(#ln, b.w) do
          buf:set(b.x + j - 1, b.y + i - 1, ln:sub(j, j),
            i <= 2 and t.palette.fg or t.palette.muted, t.palette.bg)
        end
      end
      buf:set(b.x + 11, b.y + 4, ":", t.palette.fg, t.palette.bg)
      hh_field:draw(buf, t); mm_field:draw(buf, t); apply_btn:draw(buf, t)
      self.dirty = false
    end,
    on_event = function(self, ev)
      if hh_field:on_event(ev) then return true end
      if mm_field:on_event(ev) then return true end
      if apply_btn:on_event(ev) then return true end
      return false
    end,
  })
end

local WALLPAPER_DIR = "/sys/lib/ui/wallpapers"
-- Reads the *.lua basenames out of the system wallpaper folder so the
-- list grows automatically when packages drop new patterns there. The
-- "Solid" entry is virtual: picking it writes a file that just returns
-- a fall-through pattern so wallpaper.lua takes the solid-fill branch.
local function list_wallpapers()
  local out = { "Solid" }
  for _, n in ipairs(vfs.list(WALLPAPER_DIR) or {}) do
    if n:sub(-4) == ".lua" then out[#out + 1] = n:sub(1, -5) end
  end
  table.sort(out, function(a, b)
    if a == "Solid" then return true end
    if b == "Solid" then return false end
    return a < b
  end)
  return out
end

local function wallpaper_pane()
  local home = (env and env.HOME) or "/home"
  local target = home .. "/.profile/wallpaper.lua"
  local items = list_wallpapers()
  return list_w({
    items = items, width = 24, height = math.max(#items, 4),
    on_select = function(_, name)
      local ipc = require("k.ipc")
      pcall(vfs.mkdir, home)
      pcall(vfs.mkdir, home .. "/.profile")
      if name == "Solid" then
        -- Removing the file makes wallpaper.lua's load_pattern_path
        -- return nil → draw() falls through to the solid-fill branch.
        if vfs.exists(target) then pcall(vfs.remove, target) end
      else
        -- Snapshot the system pattern's source. The wallpaper.lua loader
        -- only exposes math/string in the user file's env, so we can't
        -- use dofile/require — copying the bytes is the simplest way to
        -- give the user a self-contained pattern they could later tweak
        -- without touching /sys.
        local src_path = WALLPAPER_DIR .. "/" .. name .. ".lua"
        local body = vfs.read_all(src_path)
        if body then vfs.write_all(target, body) end
      end
      ipc.publish("ui.wallpaper.changed", { name = name })
      ipc.publish("ui.notify", { title = "Wallpaper", body = name })
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

local TAB_KEYS = {
  "settings.tab.appearance", "settings.tab.wallpaper", "settings.tab.language",
  "settings.tab.time", "settings.tab.update", "settings.tab.about",
}
local PANE_FNS = { appearance_pane, wallpaper_pane, language_pane, time_pane, update_pane, about_pane }
local function tab_labels()
  local out = {}
  for _, k in ipairs(TAB_KEYS) do out[#out + 1] = lang.t(k) end
  return out
end

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
  items = tab_labels(), width = 14, height = #TAB_KEYS, selected = 1,
  on_select = function(_, _, idx) set_pane(idx) end,
})

-- Live-update tabs and the active pane when the locale changes so the
-- user immediately sees the chosen language in the running window.
local lang_sub = require("k.ipc").subscribe("lang.changed", function()
  tabs_lst.props.items = tab_labels()
  tabs_lst:invalidate()
  set_pane(tabs_lst.state.selected or 1)
  compositor:invalidate()
end)

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

local win = session.wm:open{
  title = lang.t("settings.title"), body = body, w = 56, h = 14, x = 6, y = 4,
  on_close = function() require("k.ipc").unsubscribe(lang_sub) end,
}
-- Live-update window title on lang change as well.
require("k.ipc").subscribe("lang.changed", function()
  if win and win.props then
    win.props.title = lang.t("settings.title")
    win:invalidate()
  end
end)
return 0
