-- /apps/files.app/Main.lua — file browser with mounts panel.

local _, env, session = ...
local ui    = require("lib.ui")
local vfs   = require("k.vfs")
local widget = ui.widget
local list_w = ui.widgets.list
local label  = ui.widgets.label

if not (session and session.compositor and session.wm) then return 1 end

local cwd = (env and env.HOME) or "/"
if not vfs.isdir(cwd) then cwd = "/" end

local mounts_lst, files_lst, breadcrumb

local function entries_in(path)
  local out = { ".." }
  local lst = vfs.list(path) or {}
  table.sort(lst)
  for _, n in ipairs(lst) do
    local clean = n:gsub("/$", "")
    local full = (path == "/" and "/" or path .. "/") .. clean
    out[#out + 1] = clean .. (vfs.isdir(full) and "/" or "")
  end
  return out
end

local function set_cwd(p)
  cwd = vfs.canonical(p)
  if breadcrumb then breadcrumb.props.text = " " .. cwd; breadcrumb:invalidate() end
  if files_lst then
    files_lst.props.items = entries_in(cwd)
    files_lst.state.scroll, files_lst.state.selected = 0, 1
    files_lst:invalidate()
  end
end

local function activate_file(name)
  if name == ".." then
    if cwd == "/" then return end
    set_cwd(cwd:match("(.*)/[^/]+$") or "/")
    return
  end
  local clean = name:gsub("/$", "")
  local full = (cwd == "/" and "/" or cwd .. "/") .. clean
  if vfs.isdir(full) then set_cwd(full); return end
  if clean:match("%.lua$") or clean:match("%.txt$") or clean:match("%.md$") or clean:match("%.cfg$") then
    local edit = "/apps/edit.app/Main.lua"
    if vfs.exists(edit) then
      local fn = load(vfs.read_all(edit), "=" .. edit, "t", _G)
      if fn then pcall(fn, { full }, env, session) end
    end
  end
end

local function mount_items()
  local out = {}
  for _, m in ipairs(vfs.mounts()) do
    local lbl = m.prefix
    if lbl == "/" then lbl = "💾 boot fs"
    elseif lbl:sub(1, 5) == "/mnt/" then lbl = "💾 " .. m.prefix:sub(6)
    elseif lbl == "/tmp" then lbl = "🗂  tmpfs" end
    out[#out + 1] = lbl
  end
  out[#out + 1] = "─"
  out[#out + 1] = "🏠 Home"
  out[#out + 1] = "🖥 Desktop"
  return out
end

mounts_lst = list_w({
  items = mount_items(), width = 18, height = 12,
  on_select = function(_, _, idx)
    local mounts = vfs.mounts()
    if idx <= #mounts then set_cwd(mounts[idx].prefix); return end
    if idx == #mounts + 2 then set_cwd((env and env.HOME) or "/") end
    if idx == #mounts + 3 then set_cwd(((env and env.HOME) or "/") .. "/Desktop") end
  end,
})

files_lst = list_w({
  items = entries_in(cwd), width = 40, height = 12,
  on_select = function(_, name) activate_file(name) end,
})

breadcrumb = label({ text = " " .. cwd, fg = 0xCCCCFF, bg = 0x1F2933 })

local body = widget.new("files-body", {
  measure = function(_, mw, mh) return mw, mh end,
  _layout_children = function(self)
    local b = self.bounds
    breadcrumb:layout(b.x, b.y, b.w, 1)
    mounts_lst:layout(b.x, b.y + 1, 18, b.h - 1)
    files_lst:layout(b.x + 18, b.y + 1, b.w - 18, b.h - 1)
  end,
  draw = function(self, buf, t)
    local b = self.bounds
    buf:fill(b.x, b.y, b.w, b.h, " ", t.palette.fg, t.palette.bg)
    for _, c in ipairs(self.children) do c:draw(buf, t) end
    self.dirty = false
  end,
})
body:add_child(breadcrumb)
body:add_child(mounts_lst)
body:add_child(files_lst)

session.wm:open{
  title = "Files — " .. cwd,
  body = body, w = 64, h = 18, x = 4, y = 3,
}
return 0
