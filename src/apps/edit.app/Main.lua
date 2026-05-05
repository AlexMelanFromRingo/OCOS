-- /apps/edit.app/Main.lua — text editor.
local args, _, session = ...
local ui  = require("lib.ui")
local vfs = require("k.vfs")
local textarea = require("lib.ui.widgets.textarea")

if not (session and session.compositor and session.wm) then return 1 end

local path = args[1]
local initial = path and vfs.read_all(path) or ""
local hl = path and (path:sub(-4) == ".lua") and "lua" or nil

local editor = textarea({ text = initial, highlight = hl })
local status = ui.widgets.label({ text = " " .. (path or "<scratch>") .. "  Ctrl-S save" })

local body = ui.widget.new("edit-body", {
  measure = function(_, w, h) return w, h end,
  _layout_children = function(self)
    local b = self.bounds
    self.children[1]:layout(b.x, b.y + b.h - 1, b.w, 1)
    self.children[2]:layout(b.x, b.y, b.w, b.h - 1)
  end,
  draw = function(self, buf, theme)
    local b = self.bounds
    buf:fill(b.x, b.y, b.w, b.h, " ", theme.palette.fg, theme.palette.bg)
    for _, c in ipairs(self.children) do c:draw(buf, theme) end
    self.dirty = false
  end,
})
body:add_child(status)
body:add_child(editor)

local win = session.wm:open{
  title = path and ("Edit — " .. path) or "Edit",
  body = body, w = 70, h = 18, x = 4, y = 3,
}
editor.state.focused = true

-- Ctrl-S to save. Hook into the window's event handler.
local prev = win.on_event
win.on_event = function(self, ev)
  if ev.type == "key" and ev.down and ev.mods and ev.mods.ctrl then
    if ev.char == 19 or ev.code == 31 then  -- Ctrl-S
      if path then
        local ok, err = vfs.write_all(path, editor:text())
        status.props.text = ok and (" saved " .. path) or (" save failed: " .. tostring(err))
        status:invalidate(); return true
      end
    end
  end
  return prev(self, ev)
end

return 0
