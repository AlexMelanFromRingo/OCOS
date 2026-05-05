-- /apps/edit.app/Main.lua — text editor.
local args, _, session = ...
local ui  = require("lib.ui")
local vfs = require("k.vfs")
local textarea = require("lib.ui.widgets.textarea")

if not (session and session.compositor) then return 1 end
local compositor = session.compositor

local path = args[1]
local initial = path and vfs.read_all(path) or ""
local hl = path and (path:sub(-4) == ".lua") and "lua" or nil

local editor = textarea({ text = initial, highlight = hl })
local status = ui.widgets.label({ text = " " .. (path or "<scratch>") .. "  Ctrl-S save, Ctrl-Q quit" })

local function compose()
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
  return body
end

local win = ui.widgets.window({
  title = path and ("Edit — " .. path) or "Edit",
  w = 70, h = 22,
  body = compose(),
  on_close = function(self) self.visible = false; self:invalidate() end,
})
win:layout(4, 3, 70, 22)
compositor:add(win)
editor.state.focused = true

-- Save / quit shortcuts: intercept key events at the window level.
local original_event = win.on_event
win.on_event = function(self, ev)
  if ev.type == "key" and ev.down and ev.mods.ctrl then
    if ev.char == 19 or ev.code == 31 then  -- Ctrl-S (S = code 31)
      if path then
        local data = editor:text()
        local ok, err = vfs.write_all(path, data)
        status.props.text = ok and (" saved " .. path) or (" save failed: " .. tostring(err))
        status:invalidate(); return true
      end
    elseif ev.char == 17 or ev.code == 16 then  -- Ctrl-Q
      self.visible = false; self:invalidate(); return true
    end
  end
  return original_event(self, ev)
end

compositor:invalidate()
return 0
