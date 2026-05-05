-- /sys/lib/ui/layout.lua — flex/stack/grid layout helpers.
--
-- These produce containers with custom `:_layout_children()` that the base
-- widget calls during `layout`. They never override draw.

local M = {}

local widget = require("lib.ui.widget")

local function compute_main_offsets(items, total, gap, justify)
  -- Returns the starting offset along the main axis plus the per-item gap.
  local sizes_total = 0
  for _, s in ipairs(items) do sizes_total = sizes_total + s end
  local count = #items
  local fixed = sizes_total + math.max(0, count - 1) * gap
  local extra = total - fixed
  if extra < 0 then extra = 0 end
  if justify == "center" then return math.floor(extra / 2), gap end
  if justify == "end"    then return extra, gap end
  if justify == "between" and count > 1 then
    return 0, gap + extra / (count - 1)
  end
  if justify == "around"  and count > 0 then
    local pad = extra / count
    return pad / 2, gap + pad
  end
  return 0, gap                                    -- "start" (default)
end

local function flex(direction, props)
  local w = widget.new("flex." .. direction, {
    measure = function(self, max_w, max_h)
      local used_main, max_cross = 0, 0
      for _, c in ipairs(self.children) do
        local cw, ch = c:measure(max_w, max_h)
        local cm = direction == "row" and cw or ch
        local cc = direction == "row" and ch or cw
        used_main = used_main + cm
        if cc > max_cross then max_cross = cc end
      end
      used_main = used_main + math.max(0, #self.children - 1) * (props.gap or 0)
      if direction == "row" then
        return math.min(used_main, max_w), math.min(max_cross, max_h)
      end
      return math.min(max_cross, max_w), math.min(used_main, max_h)
    end,
    _layout_children = function(self)
      local b = self.bounds
      local sizes = {}
      for _, c in ipairs(self.children) do
        local cw, ch = c:measure(b.w, b.h)
        sizes[#sizes + 1] = direction == "row" and cw or ch
      end
      local off, step = compute_main_offsets(sizes,
        direction == "row" and b.w or b.h,
        props.gap or 0, props.justify or "start")
      local pos = (direction == "row" and b.x or b.y) + math.floor(off)
      for i, c in ipairs(self.children) do
        local cw, ch = c:measure(b.w, b.h)
        if direction == "row" then
          local cy = b.y
          if props.align == "center" then cy = b.y + math.floor((b.h - ch) / 2)
          elseif props.align == "end" then cy = b.y + b.h - ch
          elseif props.align == "stretch" then ch = b.h end
          c:layout(pos, cy, cw, ch)
          pos = pos + cw + math.floor(step)
        else
          local cx = b.x
          if props.align == "center" then cx = b.x + math.floor((b.w - cw) / 2)
          elseif props.align == "end" then cx = b.x + b.w - cw
          elseif props.align == "stretch" then cw = b.w end
          c:layout(cx, pos, cw, ch)
          pos = pos + ch + math.floor(step)
        end
      end
    end,
  }, props)
  for _, c in ipairs(props.children or {}) do w:add_child(c) end
  return w
end

function M.row(props) return flex("row", props or {}) end
function M.col(props) return flex("col", props or {}) end

function M.stack(props)
  -- Z-stack: every child fills the container; later children paint on top.
  local w = widget.new("stack", {
    _layout_children = function(self)
      local b = self.bounds
      for _, c in ipairs(self.children) do c:layout(b.x, b.y, b.w, b.h) end
    end,
  }, props or {})
  for _, c in ipairs((props or {}).children or {}) do w:add_child(c) end
  return w
end

function M.grid(props)
  local cols = props.cols or 2
  local gap  = props.gap or 0
  local w = widget.new("grid", {
    _layout_children = function(self)
      local b = self.bounds
      local rows = math.ceil(#self.children / cols)
      local cw = math.floor((b.w - gap * (cols - 1)) / cols)
      local ch = math.floor((b.h - gap * (rows - 1)) / math.max(rows, 1))
      for i, c in ipairs(self.children) do
        local row = math.floor((i - 1) / cols)
        local col = (i - 1) % cols
        c:layout(b.x + col * (cw + gap), b.y + row * (ch + gap), cw, ch)
      end
    end,
  }, props)
  for _, c in ipairs(props.children or {}) do w:add_child(c) end
  return w
end

return M
