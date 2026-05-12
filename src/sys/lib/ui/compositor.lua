-- /sys/lib/ui/compositor.lua — workspace + render loop.
--
-- A compositor owns:
--   * one `Buffer` sized to the active GPU resolution
--   * one root widget (the workspace) holding the desktop + windows
--   * an event subscription chain (kbd.key, oc.signal.touch, …)
--
-- The render loop wakes whenever a widget marks itself dirty or whenever an
-- input event arrives. It calls `:layout()` if the bounds changed, then
-- walks the tree's `:draw()` and finally `Buffer:flush(gpu)` to emit the
-- minimum number of GPU ops required to bring the screen up to date.

local M = {}

local sched   = require("k.sched")
local ipc     = require("k.ipc")
local log     = require("k.log")
local gpu     = require("drv.gpu")
local Buffer  = require("lib.ui.buffer")
local widget  = require("lib.ui.widget")
local theme_m = require("lib.ui.theme")
local event   = require("lib.ui.event")

local Compositor = {}
Compositor.__index = Compositor

function M.new(opts)
  opts = opts or {}
  local w, h = gpu.size()
  if not w or w <= 0 or not h or h <= 0 then
    return nil, "compositor requires an active GPU"
  end
  local self = setmetatable({
    buffer       = Buffer.new(w, h),
    theme        = opts.theme or theme_m.current(),
    root         = widget.new("workspace", { _layout_children = function(s)
                     for _, c in ipairs(s.children) do c:layout(s.bounds.x, s.bounds.y, s.bounds.w, s.bounds.h) end
                   end }),
    dirty        = true,
    stop         = false,
    handlers     = {},
    queue        = {},
  }, Compositor)
  self.root:layout(1, 1, w, h)
  self.root:invalidate()
  return self
end

function Compositor:add(widget_obj)
  self.root:add_child(widget_obj)
  widget_obj:layout(self.root.bounds.x, self.root.bounds.y, self.root.bounds.w, self.root.bounds.h)
  if widget_obj._layout_children then widget_obj:_layout_children() end
  return widget_obj
end

function Compositor:set_theme(theme)
  self.theme = theme
  -- Theme swap changes every fg/bg in the world, so this is the rare
  -- case where we want the prev arrays cleared.
  self:full_repaint()
end

local function any_dirty(node)
  if node.dirty then return true end
  for _, c in ipairs(node.children) do if any_dirty(c) then return true end end
  return false
end

function Compositor:render()
  if not (self.dirty or any_dirty(self.root)) then return end
  self.root:draw(self.buffer, self.theme)
  -- On T3 GPUs the driver redirects every gpu.set/fill into an
  -- off-screen buffer while in_frame, then bitblts the whole buffer
  -- to the screen atomically. On T1/T2 these are no-ops and writes
  -- go straight to the screen (mild tearing possible, no worse than
  -- before — the diff-flush still emits only changed cells).
  gpu.begin_frame()
  self.buffer:flush(gpu)
  gpu.end_frame()
  self.dirty = false
end

function Compositor:dispatch(ev)
  -- The window manager (when attached) gets a first crack at every
  -- event so it can manage drag/resize and global shortcuts before
  -- widgets see it.
  if self.wm and self.wm:handle_global_event(ev) then
    self:render(); return
  end
  self.root:on_event(ev)
  self:render()
end

function Compositor:attach_wm(wm)
  self.wm = wm
end

local TICK = "__ui_tick"

local function enqueue(self, ev)
  self.queue[#self.queue + 1] = ev
  computer.pushSignal(TICK)
end

local function wire_inputs(self)
  -- Subscribers translate raw IPC payloads into typed events and enqueue
  -- them. The render loop drains the queue, so all rendering happens in a
  -- single coroutine context — no double-paints from concurrent subscribers.
  self.handlers[#self.handlers + 1] = ipc.subscribe("kbd.key", function(p)
    enqueue(self, event.key(p.down, p.char, p.code, p.mods, p.player))
  end)
  self.handlers[#self.handlers + 1] = ipc.subscribe("kbd.paste", function(p)
    enqueue(self, event.paste(p.value, p.player))
  end)

  for raw, factory in pairs({
    ["oc.signal.touch"]  = function(a) return event.touch(a[2], a[3], a[4], a[5]) end,
    ["oc.signal.drag"]   = function(a) return event.drag(a[2], a[3], a[4], a[5]) end,
    ["oc.signal.drop"]   = function(a) return event.drop(a[2], a[3], a[4], a[5]) end,
    ["oc.signal.scroll"] = function(a) return event.scroll(a[2], a[3], a[4], a[5]) end,
    ["oc.signal.screen_resized"] = function(a) return event.resize(a[2], a[3]) end,
  }) do
    self.handlers[#self.handlers + 1] = ipc.subscribe(raw, function(args)
      enqueue(self, factory(args))
    end)
  end
end

function Compositor:run()
  wire_inputs(self)
  self:render()
  while not self.stop do
    sched.wait(function(name) return name == TICK end, 1)
    while #self.queue > 0 do
      local ev = table.remove(self.queue, 1)
      if ev.type == "resize" then
        self.buffer:resize(ev.w, ev.h)
        if gpu.reset_backbuffer then gpu.reset_backbuffer() end
        self.root:layout(1, 1, ev.w, ev.h)
        self.root:invalidate()
      end
      -- Route through the WM first so global drag / resize / Alt-Tab
      -- gestures are handled before the widget tree sees the event.
      -- Without this, dragging the title bar never updated window
      -- bounds — the click reached the window widget directly and the
      -- WM's drag bookkeeping in `:dispatch` was bypassed.
      if not (self.wm and self.wm:handle_global_event(ev)) then
        self.root:on_event(ev)
      end
    end
    self:render()
  end
  for _, h in ipairs(self.handlers) do ipc.unsubscribe(h) end
end

function Compositor:request_stop() self.stop = true; computer.pushSignal(TICK) end

function Compositor:size() return self.buffer:size() end

-- `invalidate` requests a re-render but trusts the diff-flush in
-- Buffer:flush to push only the cells that actually changed. Callers
-- that need an unconditional repaint (theme swap, screen resize) call
-- `full_repaint` instead — it resets the prev cell arrays so every
-- cell is treated as dirty on the next flush. The day-to-day tick
-- (clock, taskbar chips) goes through `invalidate` and stays cheap.
function Compositor:invalidate()
  self.dirty = true
  computer.pushSignal(TICK)
end
function Compositor:full_repaint()
  self.dirty = true
  self.buffer:invalidate()
  computer.pushSignal(TICK)
end

M.Compositor = Compositor
return M
