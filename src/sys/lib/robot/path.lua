-- /sys/lib/robot/path.lua — field-traversal iterators for robot tasks.
--
-- The infamous "even-width snake doesn't come back to origin" bug
-- comes from counting steps and turns instead of tracking absolute
-- coordinates. Pair these iterators with lib/robot/nav (which knows
-- where it is in absolute coords) and the parity goes away — the
-- iterator just yields target cells, nav goes to each in turn, and
-- nav:home() returns to (0, 0, 0) regardless of the field shape.
--
-- Public API:
--   path.snake(width, height) -> iterator yielding (x, z) on each step
--   path.spiral(width, height) -> outside-in spiral; useful when you
--                                  want the robot to keep one neighbour
--                                  for orientation as it works inward.
--   path.rows(width, height)  -> simple row-by-row, robot returns to
--                                start of row each line. Slower but
--                                wall-friendly when there's a fence.
--
-- All iterators yield (x, z) integer pairs in 1..width × 1..height.
-- A typical use:
--
--   local nav = require("lib.robot.nav").new()
--   for x, z in path.snake(W, H) do
--     nav:goto_xz(x - 1, z - 1)                  -- 0-based coords
--     -- do work at the cell (harvest, place, scan)
--   end
--   nav:home()
--
-- Yes, "snake" works for any width AND height, including even ones —
-- because the iterator is the source of truth and the robot follows
-- it. Don't bake the parity into the robot's loop; that's the whole
-- mistake.

local M = {}

function M.snake(width, height)
  local x, z = 0, 1                                  -- start at (1, 1) on first call
  local going_right = true
  return function()
    if z > height then return nil end
    if going_right then
      x = x + 1
      if x > width then
        x = width
        z = z + 1
        going_right = false
        if z > height then return nil end
      end
    else
      x = x - 1
      if x < 1 then
        x = 1
        z = z + 1
        going_right = true
        if z > height then return nil end
      end
    end
    return x, z
  end
end

function M.rows(width, height)
  local x, z = 0, 1
  return function()
    if z > height then return nil end
    x = x + 1
    if x > width then
      x = 1
      z = z + 1
      if z > height then return nil end
    end
    return x, z
  end
end

function M.spiral(width, height)
  -- Generate the cell list eagerly into a table, then return an
  -- iterator over it. Outside-in: top edge → right edge → bottom
  -- edge → left edge, then shrink the box and repeat.
  local cells = {}
  local x1, x2, z1, z2 = 1, width, 1, height
  while x1 <= x2 and z1 <= z2 do
    for x = x1, x2 do cells[#cells + 1] = { x, z1 } end
    z1 = z1 + 1
    if z1 > z2 then break end
    for z = z1, z2 do cells[#cells + 1] = { x2, z } end
    x2 = x2 - 1
    if x1 > x2 then break end
    for x = x2, x1, -1 do cells[#cells + 1] = { x, z2 } end
    z2 = z2 - 1
    if z1 > z2 then break end
    for z = z2, z1, -1 do cells[#cells + 1] = { x1, z } end
    x1 = x1 + 1
  end
  local i = 0
  return function()
    i = i + 1
    local c = cells[i]
    if c then return c[1], c[2] end
    return nil
  end
end

return M
