-- /apps/files.app/Main.lua — file browser.
--
-- Layout (per window body):
--   ┌───── path breadcrumb ─────────────────────────────────┐
--   │ > home > alex > Desktop                                │
--   ├──── places ────┬───── entries ────────────────────────┤
--   │  Home          │  📁 docs/                            │
--   │  Desktop       │  📄 readme.txt              42 B      │
--   │  ─             │  ⚙  config.cfg              128 B    │
--   │  💾 boot       │  ...                                  │
--   │  💾 cda34cf4   │                                       │
--   └────────────────┴───────────────────────────────────────┘
--   3 items · readme.txt: 42 B
--
-- The places list and entry list are independent list widgets; their
-- click handlers feed back into a single `set_cwd` that updates both
-- panes plus the breadcrumb and the bottom status bar.

local _, env, session = ...
local ui     = require("lib.ui")
local vfs    = require("k.vfs")
local ipc    = require("k.ipc")
local widget = ui.widget
local list_w = ui.widgets.list

if not (session and session.compositor and session.wm) then return 1 end

local cwd = (env and env.HOME) or "/"
if not vfs.isdir(cwd) then cwd = "/" end

-- ---- helpers -----------------------------------------------------------

-- Classify a path for icon + colour + handler routing. Glyphs are
-- ASCII-friendly: the OC font ships a small subset of unicode, and the
-- 4-byte emoji we used earlier render as garbage on a real screen.
-- Default to "text" for anything that isn't an obvious binary blob —
-- shell history files (.sh_history), traces, READMEs etc. should all
-- open in the editor instead of throwing "no handler".
local KNOWN_BINARY = {
  png = true, ocif = true, ocbm = true, jpg = true, jpeg = true, gif = true,
  ocpkg = true, tar = true, zip = true, gz = true, bin = true, eep = true,
}
local function classify(full, name)
  if vfs.isdir(full) then return "dir", "/", 0x4FA0F0 end
  local ext = name:match("%.([^.]+)$")
  ext = ext and ext:lower()
  if ext == "lua" then return "lua",   "L", 0x66DD66 end
  if ext == "cfg" or ext == "ini" or ext == "toml" then return "cfg", "C", 0xE0C040 end
  if ext == "png" or ext == "ocif" or ext == "ocbm" then return "img", "P", 0xCC66CC end
  if ext == "ocpkg" or ext == "tar" or ext == "zip" then return "pkg", "K", 0xE05050 end
  if ext and KNOWN_BINARY[ext] then return "file", ".", 0xCCCCCC end
  -- Everything else (txt, md, log, trace, sh_history, history,
  -- conf, profile, no-extension files) is text-shaped → editor.
  return "text", "T", 0xCCCCCC
end

local function fmt_size(bytes)
  if not bytes then return "" end
  if bytes < 1024 then return bytes .. " B" end
  if bytes < 1024*1024 then return string.format("%.1f K", bytes/1024) end
  return string.format("%.1f M", bytes/1024/1024)
end

-- Each row is an opaque table; the list widget renders via props.format.
local function entries_in(path)
  local out = {}
  -- ".." pseudo-entry, except at root.
  if path ~= "/" then
    out[#out + 1] = { name = "..", kind = "dir", glyph = "↩", fg = 0x808080, size = nil }
  end
  local lst = vfs.list(path) or {}
  table.sort(lst, function(a, b)
    local an = a:gsub("/$", ""); local bn = b:gsub("/$", "")
    local ad = a:sub(-1) == "/"; local bd = b:sub(-1) == "/"
    if ad ~= bd then return ad end                    -- dirs first
    return an:lower() < bn:lower()
  end)
  for _, raw in ipairs(lst) do
    local clean = raw:gsub("/$", "")
    local full = (path == "/" and "/" or path .. "/") .. clean
    local kind, glyph, fg = classify(full, clean)
    out[#out + 1] = {
      name = clean, kind = kind, glyph = glyph, fg = fg,
      size = (kind ~= "dir") and vfs.size(full) or nil,
      full = full,
    }
  end
  return out
end

-- ---- widgets ------------------------------------------------------------

local breadcrumb = widget.new("breadcrumb", {
  state = { path = cwd },
  measure = function(_, mw) return mw, 1 end,
  draw = function(self, buf, theme)
    local b = self.bounds
    local fg = 0xE6E6E6
    local bg = 0x1A2B40
    buf:fill(b.x, b.y, b.w, 1, " ", fg, bg)
    local segs = {}
    for s in (self.state.path .. "/"):gmatch("([^/]+)/") do segs[#segs + 1] = s end
    local x = b.x + 2
    -- "/" prefix as a leading slash glyph
    buf:set(x - 1, b.y, "/", theme.palette.muted or 0x888888, bg)
    for i, s in ipairs(segs) do
      if x + #s > b.x + b.w - 1 then break end
      for j = 1, #s do buf:set(x + j - 1, b.y, s:sub(j, j), fg, bg); end
      x = x + #s
      if i < #segs then
        buf:set(x, b.y, "/", theme.palette.muted or 0x888888, bg)
        x = x + 1
      end
    end
    self.dirty = false
  end,
})

local statusbar = widget.new("statusbar", {
  state = { text = "" },
  measure = function(_, mw) return mw, 1 end,
  draw = function(self, buf, theme)
    local b = self.bounds
    buf:fill(b.x, b.y, b.w, 1, " ", theme.palette.muted or 0x888888,
      theme.palette.surface or 0x2A2A2A)
    local s = " " .. (self.state.text or "")
    for i = 1, math.min(#s, b.w) do
      buf:set(b.x + i - 1, b.y, s:sub(i, i),
        theme.palette.muted or 0x888888,
        theme.palette.surface or 0x2A2A2A)
    end
    self.dirty = false
  end,
})

-- Mount table → "places" entries. ASCII glyphs only so the sidebar
-- reads the same on every machine; recomputed on each cwd change so a
-- newly mounted disk shows up without relaunching the app.
local function place_items()
  local home = (env and env.HOME) or "/home"
  local out = {
    { label = "Home",       path = home    },
    { label = "Desktop",    path = home .. "/Desktop" },
    { label = "Root /",     path = "/"     },
  }
  for _, m in ipairs(vfs.mounts()) do
    if m.prefix:sub(1, 5) == "/mnt/" then
      local short = m.prefix:sub(6, 13)
      out[#out + 1] = { label = "fs " .. short, path = m.prefix }
    end
  end
  return out
end

local entries_lst, places_lst

local function set_cwd(p)
  cwd = vfs.canonical(p)
  if not vfs.isdir(cwd) then cwd = "/" end
  breadcrumb.state.path = cwd
  breadcrumb:invalidate()
  entries_lst.props.items = entries_in(cwd)
  entries_lst.state.scroll = 0
  entries_lst.state.selected = 1
  entries_lst:invalidate()
  statusbar.state.text = string.format("%d items", #entries_lst.props.items)
  statusbar:invalidate()
end

local function activate(item)
  if not item then return end
  if item.name == ".." then
    if cwd == "/" then return end
    set_cwd(cwd:match("(.*)/[^/]+$") or "/")
    return
  end
  local full = item.full
  if not full then return end
  if item.kind == "dir" then set_cwd(full); return end
  -- Anything text-shaped opens in the editor; binary blobs (img, pkg,
  -- unknown) get a notify rather than a crash from feeding non-text
  -- bytes to a textarea.
  if item.kind == "lua" or item.kind == "text" or item.kind == "cfg" then
    local edit = "/apps/edit.app/Main.lua"
    if vfs.exists(edit) then
      local fn = load(vfs.read_all(edit), "=" .. edit, "t", _G)
      if fn then pcall(fn, { full }, env, session) end
    end
  else
    ipc.publish("ui.notify", {
      title = "Files", body = "No handler for " .. item.name, level = "warn",
    })
  end
end

places_lst = list_w({
  items = place_items(), width = 16, height = 16,
  format = function(it) return it.label end,
  on_select = function(_, item)
    if item and item.path then set_cwd(item.path) end
  end,
})

entries_lst = list_w({
  items = entries_in(cwd), width = 40, height = 16,
  format = function(it)
    local glyph = it.glyph or "  "
    local size  = it.size and fmt_size(it.size) or ""
    -- pad to roughly column-aligned: glyph (2) + name (var) + right-aligned size
    return string.format("%s  %s", glyph, it.name)
            .. string.rep(" ", math.max(1, 28 - #it.name))
            .. size
  end,
  on_select = function(_, item, idx)
    -- Surface size of selected item in the status bar.
    if item and item.name ~= ".." and item.size then
      statusbar.state.text = string.format("%d items · %s: %s",
        #entries_lst.props.items, item.name, fmt_size(item.size))
      statusbar:invalidate()
    end
    activate(item)
  end,
})

-- ---- root composition ---------------------------------------------------

local body = widget.new("files-body", {
  measure = function(_, mw, mh) return mw, mh end,
  _layout_children = function(self)
    local b = self.bounds
    breadcrumb:layout(b.x, b.y,             b.w,       1)
    places_lst:layout(b.x, b.y + 1,         16,        b.h - 2)
    entries_lst:layout(b.x + 17, b.y + 1,   b.w - 17,  b.h - 2)
    statusbar:layout(b.x, b.y + b.h - 1,    b.w,       1)
  end,
  draw = function(self, buf, t)
    local b = self.bounds
    buf:fill(b.x, b.y + 1, b.w, b.h - 2, " ", t.palette.fg, t.palette.bg)
    -- Vertical separator between places and entries.
    for y = b.y + 1, b.y + b.h - 2 do
      buf:set(b.x + 16, y, "│", t.palette.muted or 0x666666, t.palette.bg)
    end
    for _, c in ipairs(self.children) do c:draw(buf, t) end
    self.dirty = false
  end,
})
body:add_child(breadcrumb)
body:add_child(places_lst)
body:add_child(entries_lst)
body:add_child(statusbar)

statusbar.state.text = string.format("%d items", #entries_lst.props.items)

session.wm:open{
  title = "Files",
  body  = body,
  w     = 64, h = 20, x = 4, y = 3,
}

return 0
