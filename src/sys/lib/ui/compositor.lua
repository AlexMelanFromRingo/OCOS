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
  self.buffer:invalidate()
  self.dirty = true
end

local function any_dirty(node)
  if node.dirty then return true end
  for _, c in ipairs(node.children) do if any_dirty(c) then return true end end
  return false
end

function Compositor:render()
  if not (self.dirty or any_dirty(self.root)) then return end
  self.root:draw(self.buffer, self.theme)
  self.buffer:flush(gpu)
  self.dirty = false
end

function Compositor:dispatch(ev)
  -- Walk into root; let widgets claim the event. Always render afterwards
  -- since event handlers commonly call :invalidate().
  self.root:on_event(ev)
  self:render()
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
        self.root:layout(1, 1, ev.w, ev.h)
        self.root:invalidate()
      end
      self.root:on_event(ev)
    end
    self:render()
  end
  for _, h in ipairs(self.handlers) do ipc.unsubscribe(h) end
end

function Compositor:request_stop() self.stop = true; computer.pushSignal(TICK) end

function Compositor:size() return self.buffer:size() end
function Compositor:invalidate() self.dirty = true; self.buffer:invalidate() end

M.Compositor = Compositor
return M
