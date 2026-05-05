-- /sys/lib/ui/wm.lua — window manager.
--
-- Owns a list of open windows with z-order, focus tracking, drag/resize
-- gestures and the keyboard shortcuts that act globally (focus next
-- window, minimise, maximise, close). Sits inside a compositor as a
-- single widget; windows are its children. Re-orders children when a
-- window gains focus so painting picks up the right z-order naturally.
--
-- Public API:
--   wm = WM.new(compositor)
--   win = wm:open{ title=, body=, w=, h=, x=, y=, on_close=, ... }
--   wm:close(win)        wm:focus(win)
--   wm:minimise(win)     wm:maximise(win)     wm:restore(win)
--   wm:windows()         array of {win, state} for taskbar
--   wm:on_power(action)  action = "lock"|"logout"|"reboot"|"shutdown"|"switch"

local M = {}

local widget = require("lib.ui.widget")
local Window = require("lib.ui.widgets.window")

local WM = {}
WM.__index = WM

local MIN_W, MIN_H = 20, 5

function M.new(compositor)
  local self = setmetatable({
    compositor = compositor,
    windows    = {},                              -- z-stack, last = front
    focused    = nil,
    drag       = nil,                             -- in-flight drag/resize state
    listeners  = {},                              -- for wm:windows_changed
  }, WM)
  -- A workspace widget that draws windows in z-order. Crucially it
  -- DOES NOT fill its own bounds — clearing the workspace area would
  -- erase the wallpaper, desktop icons and any sibling that paints
  -- earlier (status bar, taskbar). Each window paints opaquely over
  -- whatever is behind it; gaps stay transparent.
  self.root = widget.new("workspace", {
    measure = function(_, mw, mh) return mw, mh end,
    _layout_children = function(s) end,
    draw = function(s, buf, theme)
      for _, c in ipairs(s.children) do
        if c.visible then c:draw(buf, theme) end
      end
      s.dirty = false
    end,
    on_event = function(s, ev)
      for i = #s.children, 1, -1 do
        if s.children[i].visible and s.children[i]:on_event(ev) then
          return true
        end
      end
      return false
    end,
  })
  self._mounted = false
  return self
end

function WM:mount()
  if self._mounted then return end
  self.compositor:add(self.root)
  self._mounted = true
end

function WM:notify_changed()
  for _, fn in ipairs(self.listeners) do pcall(fn, self) end
end

function WM:on_changed(fn) self.listeners[#self.listeners + 1] = fn end

local function default_bounds(self, w, h)
  -- Coordinates are absolute screen cells. wm.root sits in the middle
  -- band of the desktop (between status bar and taskbar), so we offset
  -- by its bounds.x / bounds.y — otherwise the very first window opens
  -- at (2, 1) and punches a hole through the status bar.
  local b = self.root.bounds
  if not b or b.w <= 0 or b.h <= 0 then
    local sw, sh = self.compositor:size()
    b = { x = 1, y = 1, w = sw or 80, h = sh or 25 }
  end
  w = math.max(MIN_W, math.min(w or 60, b.w - 2))
  h = math.max(MIN_H, math.min(h or 18, b.h - 2))
  local n = #self.windows
  local x = b.x + 1 + (n * 2) % math.max(1, b.w - w - 4)
  local y = b.y     + (n * 2) % math.max(1, b.h - h - 4)
  return x, y, w, h
end

function WM:open(opts)
  opts = opts or {}
  self:mount()
  local x, y, w, h = default_bounds(self, opts.w, opts.h)
  if opts.x then x = opts.x end
  if opts.y then y = opts.y end

  local win = Window({
    title       = opts.title or "Window",
    closable    = opts.closable    ~= false,
    minimisable = opts.minimisable ~= false,
    maximisable = opts.maximisable ~= false,
    resizable   = opts.resizable   ~= false,
    body        = opts.body,
    on_close    = function(w_)
      if opts.on_close then pcall(opts.on_close, w_) end
      self:close(w_)
    end,
    on_min   = function(w_) self:minimise(w_) end,
    on_max   = function(w_) self:toggle_maximise(w_) end,
    on_focus = function(w_) self:focus(w_) end,
    on_drag_start = function(w_, kind, sx, sy)
      self.drag = { win = w_, kind = kind, sx = sx, sy = sy,
                    bx = w_.bounds.x, by = w_.bounds.y,
                    bw = w_.bounds.w, bh = w_.bounds.h }
    end,
    on_drag_end = function() self.drag = nil end,
  })
  win.wm_state = { state = "normal", saved = nil, app_title = opts.title or "Window" }
  win:layout(x, y, w, h)
  self.root:add_child(win)
  self.windows[#self.windows + 1] = win
  self:focus(win)
  self:notify_changed()
  return win
end

local function index_of(t, v)
  for i, x in ipairs(t) do if x == v then return i end end
end

function WM:focus(win)
  if not win or not win.visible then return end
  local i = index_of(self.windows, win)
  if not i then return end
  -- Move to top of both our list and root's children
  table.remove(self.windows, i)
  self.windows[#self.windows + 1] = win
  local ci = index_of(self.root.children, win)
  if ci then
    table.remove(self.root.children, ci)
    self.root.children[#self.root.children + 1] = win
  end
  for _, w in ipairs(self.windows) do w.state.focused = (w == win) end
  self.focused = win
  self.root:invalidate()
  self:notify_changed()
end

function WM:close(win)
  local i = index_of(self.windows, win)
  if not i then return end
  table.remove(self.windows, i)
  local ci = index_of(self.root.children, win)
  if ci then table.remove(self.root.children, ci); win.parent = nil end
  if self.focused == win then
    self.focused = self.windows[#self.windows]
    if self.focused then self.focused.state.focused = true end
  end
  self.root:invalidate()
  self:notify_changed()
end

function WM:minimise(win)
  win.wm_state.state = "minimised"
  win.visible = false
  if self.focused == win then
    -- Focus next visible window
    self.focused = nil
    for i = #self.windows, 1, -1 do
      if self.windows[i].visible then self:focus(self.windows[i]); break end
    end
  end
  self.root:invalidate()
  self:notify_changed()
end

function WM:restore_window(win)
  win.visible = true
  if win.wm_state.state == "maximised" and win.wm_state.saved then
    -- stay maximised
  end
  win.wm_state.state = (win.wm_state.state == "maximised") and "maximised" or "normal"
  self:focus(win)
end

function WM:toggle_maximise(win)
  if win.wm_state.state == "maximised" then
    -- restore
    local s = win.wm_state.saved
    if s then win:layout(s.x, s.y, s.w, s.h) end
    win.wm_state.state = "normal"
  else
    -- save + maximise
    win.wm_state.saved = { x = win.bounds.x, y = win.bounds.y,
                           w = win.bounds.w, h = win.bounds.h }
    local b = self.root.bounds
    win:layout(b.x, b.y, b.w, b.h)
    win.wm_state.state = "maximised"
  end
  self.root:invalidate()
  self:notify_changed()
end

function WM:focus_next(reverse)
  if #self.windows < 2 then return end
  local cur = index_of(self.windows, self.focused) or #self.windows
  -- Find next visible
  local n = #self.windows
  for step = 1, n do
    local i = ((cur - 1 + (reverse and -step or step)) % n) + 1
    if self.windows[i].visible then self:focus(self.windows[i]); return end
  end
end

function WM:windows_for_taskbar()
  local out = {}
  for _, w in ipairs(self.windows) do
    out[#out + 1] = {
      title = w.wm_state.app_title or w.props.title,
      minimised = w.wm_state.state == "minimised",
      focused = (w == self.focused) and w.visible,
      win = w,
    }
  end
  return out
end

function WM:click_taskbar(win)
  if win.wm_state.state == "minimised" then
    win.visible = true
    win.wm_state.state = "normal"
    self:focus(win)
  elseif self.focused == win then
    self:minimise(win)
  else
    self:focus(win)
  end
end

-- ---- input dispatch -----------------------------------------------------
-- The compositor walks self.root with on_event. Window widgets handle
-- their own clicks. We hook into compositor's event chain via the root
-- to capture global drag (if a drag started on a title-bar) and global
-- keyboard shortcuts.

function WM:handle_global_event(ev)
  if ev.type == "drag" and self.drag then
    local d = self.drag
    if d.kind == "move" then
      local nx = d.bx + (ev.x - d.sx)
      local ny = d.by + (ev.y - d.sy)
      local b = self.root.bounds
      nx = math.max(b.x, math.min(nx, b.x + b.w - d.bw))
      ny = math.max(b.y, math.min(ny, b.y + b.h - d.bh))
      d.win:layout(nx, ny, d.bw, d.bh)
      self.root:invalidate()
      return true
    elseif d.kind == "resize" then
      local nw = math.max(MIN_W, d.bw + (ev.x - d.sx))
      local nh = math.max(MIN_H, d.bh + (ev.y - d.sy))
      local b = self.root.bounds
      nw = math.min(nw, b.x + b.w - d.bx)
      nh = math.min(nh, b.y + b.h - d.by)
      d.win:layout(d.bx, d.by, nw, nh)
      self.root:invalidate()
      return true
    end
  elseif ev.type == "drop" and self.drag then
    self.drag = nil
    return true
  elseif ev.type == "key" and ev.down then
    -- Global shortcuts
    local c = ev.code
    local m = ev.mods or {}
    if m.alt and c == 15 then          -- Alt+Tab
      self:focus_next(m.shift)
      return true
    elseif m.super and ev.char == 23 then -- Win+W → close window
      if self.focused then
        if self.focused.props.on_close then self.focused.props.on_close(self.focused) end
      end
      return true
    elseif c == 87 then                 -- F11 → maximise toggle
      if self.focused then self:toggle_maximise(self.focused) end
      return true
    elseif m.ctrl and m.alt and (c == 200 or c == 208 or c == 203 or c == 205) then
      if self.focused then
        local b = self.focused.bounds
        local dw, dh = 0, 0
        if c == 200 then dh = -2 end       -- up
        if c == 208 then dh =  2 end       -- down
        if c == 203 then dw = -4 end       -- left
        if c == 205 then dw =  4 end       -- right
        local nw = math.max(MIN_W, b.w + dw)
        local nh = math.max(MIN_H, b.h + dh)
        self.focused:layout(b.x, b.y, nw, nh)
        self.root:invalidate()
      end
      return true
    elseif m.alt and (c == 200 or c == 208 or c == 203 or c == 205) then
      if self.focused then
        local b = self.focused.bounds
        local dx, dy = 0, 0
        if c == 200 then dy = -2 end
        if c == 208 then dy =  2 end
        if c == 203 then dx = -4 end
        if c == 205 then dx =  4 end
        self.focused:layout(b.x + dx, b.y + dy, b.w, b.h)
        self.root:invalidate()
      end
      return true
    end
  end
  return false
end

return M
