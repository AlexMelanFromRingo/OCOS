-- /apps/files.app/Main.lua — minimal file browser.
local _, _, session = ...
local ui  = require("lib.ui")
local vfs = require("k.vfs")

if not (session and session.compositor) then return 1 end
local compositor = session.compositor

local cwd = "/"
local list, path_label

local function refresh()
  local entries = vfs.list(cwd) or {}
  table.sort(entries)
  local items = { ".." }
  for _, name in ipairs(entries) do
    local full = cwd == "/" and "/" .. name or cwd .. "/" .. name
    items[#items + 1] = name .. (vfs.isdir(full) and "/" or "")
  end
  list.props.items = items
  list.state.selected, list.state.scroll = 1, 0
  list:invalidate()
  path_label.props.text = " " .. cwd
  path_label:invalidate()
end

local function activate(item)
  if item == ".." then
    cwd = vfs.canonical(cwd .. "/..")
    refresh(); return
  end
  local target = item:sub(-1) == "/" and item:sub(1, -2) or item
  local full = cwd == "/" and "/" .. target or cwd .. "/" .. target
  if vfs.isdir(full) then cwd = vfs.canonical(full); refresh() end
end

list = ui.widgets.list({
  items = {}, width = 50, height = 18,
  on_activate = function(_, it) activate(it) end,
  on_select   = function(_, _) end,
})
path_label = ui.widgets.label({ text = " /", align = "start" })

local body = ui.widget.new("files-body", {
  measure = function(_, w, h) return w, h end,
  _layout_children = function(self)
    local b = self.bounds
    self.children[1]:layout(b.x, b.y, b.w, 1)
    self.children[2]:layout(b.x, b.y + 1, b.w, b.h - 1)
  end,
  draw = function(self, buf, theme)
    local b = self.bounds
    buf:fill(b.x, b.y, b.w, b.h, " ", theme.palette.fg, theme.palette.bg)
    for _, c in ipairs(self.children) do c:draw(buf, theme) end
    self.dirty = false
  end,
})
body:add_child(path_label)
body:add_child(list)

local win = ui.widgets.window({
  title = "Files", w = 54, h = 22,
  body = body,
  on_close = function(self) self.visible = false; self:invalidate() end,
})
win:layout(8, 4, 54, 22)
compositor:add(win)
refresh()
list.state.focused = true
compositor:invalidate()
return 0
