-- /sys/lib/ui/widget.lua — base widget type.
--
-- A widget is a plain table with a small set of methods:
--   :measure(max_w, max_h) -> w, h        preferred size given constraints
--   :layout(x, y, w, h)                   actual bounds; recurses into children
--   :draw(buffer, theme)                  paint into the compositor buffer
--   :on_event(ev) -> handled?             input handling; returns true to stop
--   :invalidate()                         marks self dirty for the next frame
--
-- Widgets carry a `kind` string (e.g. "button"), a `props` table for caller
-- state, a `state` table for runtime state (focused, hovered, pressed), and a
-- `children` array. The compositor walks the tree top-down for measure +
-- layout, then top-down for draw (children paint after their parent), and
-- bottom-up for events (deepest child gets first refusal).

local M = {}

local Widget = {}
Widget.__index = Widget

local id_seq = 0
function M.new(kind, methods, props)
  id_seq = id_seq + 1
  local self = setmetatable({
    id        = id_seq,
    kind      = kind,
    props     = props or {},
    state     = {},
    children  = {},
    parent    = nil,
    bounds    = { x = 0, y = 0, w = 0, h = 0 },
    visible   = true,
    dirty     = true,
  }, Widget)
  for k, v in pairs(methods or {}) do self[k] = v end
  return self
end

function Widget:add_child(child)
  child.parent = self
  self.children[#self.children + 1] = child
  self:invalidate()
  return child
end

function Widget:remove_children()
  for _, c in ipairs(self.children) do c.parent = nil end
  self.children = {}
  self:invalidate()
end

function Widget:invalidate()
  self.dirty = true
  if self.parent then self.parent:invalidate() end
end

function Widget:measure(max_w, max_h)
  -- Default: own size or max constraints; subclasses override.
  local w = self.props.w or max_w
  local h = self.props.h or max_h
  return math.min(w, max_w), math.min(h, max_h)
end

function Widget:layout(x, y, w, h)
  self.bounds.x, self.bounds.y, self.bounds.w, self.bounds.h = x, y, w, h
  self.dirty = true
  if self._layout_children then self:_layout_children() end
end

function Widget:draw(buffer, theme)
  -- Default container behaviour: clear bounds, paint children. Leaf widgets
  -- override this entirely.
  local b = self.bounds
  buffer:fill(b.x, b.y, b.w, b.h, " ", theme.palette.fg, theme.palette.bg)
  for _, c in ipairs(self.children) do
    if c.visible then c:draw(buffer, theme) end
  end
  self.dirty = false
end

function Widget:hit(x, y)
  local b = self.bounds
  return x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h
end

function Widget:on_event(ev)
  -- Bottom-up dispatch: try children (last to first so top-most wins),
  -- then self-handler from props.on_event if defined.
  if (ev.type == "touch" or ev.type == "drag" or ev.type == "drop"
      or ev.type == "scroll") and not self:hit(ev.x, ev.y) then
    return false
  end
  for i = #self.children, 1, -1 do
    if self.children[i].visible and self.children[i]:on_event(ev) then
      return true
    end
  end
  if self.props.on_event then return self.props.on_event(self, ev) and true or false end
  return false
end

M.Widget = Widget
return M
