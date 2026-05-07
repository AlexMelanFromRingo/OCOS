-- /sys/lib/robot/nav.lua — coordinate-tracking robot navigation.
--
-- Wraps OC's `robot` component with a position + facing model so high-
-- level callers (farm, sort, build) can ask "go to (x, y, z)" and get
-- there reliably regardless of where the robot is right now. The
-- underlying robot.forward() / turnLeft() / turnRight() calls are
-- exactly the same OC ones; we just keep the bookkeeping correct.
--
-- Conventions:
--
--   * The robot starts at origin (0, 0, 0) facing FORWARD (= +x).
--   * Facing values: 0 = +x (forward), 1 = -z (left), 2 = -x (back),
--     3 = +z (right). turnLeft increments facing mod 4; turnRight
--     decrements. Pure cardinal — no diagonal motion.
--   * The naive goto() path moves along z first (left/right), then x
--     (forward/back), then y (vertical). Good enough for open fields
--     and chest rooms; pathfinding around obstacles is up to higher
--     layers if they want it.
--
-- Public API:
--   nav.new()
--   n:forward() / back() / up() / down()       move + update coords
--   n:turn_left() / turn_right() / turn_around()
--   n:face(dir)                                 turn to dir 0..3
--   n:goto_xz(x, z) / goto(x, y, z)            walk to coordinate
--   n:home()                                    goto (0,0,0) facing 0
--   n:where()                                   {x, y, z, facing}
--
-- Each move method returns ok, err exactly like the underlying
-- robot.forward() etc. — so callers can detect "blocked by entity"
-- and decide to retry / swing / wait.

local M = {}

local Nav = {}
Nav.__index = Nav

local function get_robot()
  if _G.component and _G.component.robot then return _G.component.robot end
  if _G.component and _G.component.list then
    local addr = _G.component.list("robot")()
    if addr then return _G.component.proxy(addr) end
  end
  return nil
end

function M.new()
  local r = get_robot()
  if not r then return nil, "no robot component" end
  return setmetatable({
    r       = r,
    x       = 0, y = 0, z = 0,
    facing  = 0,                                -- 0=+x, 1=-z, 2=-x, 3=+z
  }, Nav)
end

function Nav:where()
  return { x = self.x, y = self.y, z = self.z, facing = self.facing }
end

-- Cardinal delta for the current facing. Call after a successful
-- forward/back to update (x, z).
local DELTA = { [0] = { 1, 0 }, [1] = { 0, -1 }, [2] = { -1, 0 }, [3] = { 0, 1 } }

function Nav:forward()
  local ok, err = self.r.forward()
  if ok then
    local d = DELTA[self.facing]
    self.x = self.x + d[1]
    self.z = self.z + d[2]
  end
  return ok, err
end

function Nav:back()
  local ok, err = self.r.back()
  if ok then
    local d = DELTA[self.facing]
    self.x = self.x - d[1]
    self.z = self.z - d[2]
  end
  return ok, err
end

function Nav:up()
  local ok, err = self.r.up()
  if ok then self.y = self.y + 1 end
  return ok, err
end

function Nav:down()
  local ok, err = self.r.down()
  if ok then self.y = self.y - 1 end
  return ok, err
end

function Nav:turn_left()
  local ok, err = self.r.turnLeft()
  if ok then self.facing = (self.facing + 1) % 4 end
  return ok, err
end

function Nav:turn_right()
  local ok, err = self.r.turnRight()
  if ok then self.facing = (self.facing - 1) % 4 end
  return ok, err
end

function Nav:turn_around()
  local ok = self:turn_right(); if not ok then return ok end
  return self:turn_right()
end

function Nav:face(dir)
  dir = dir % 4
  while self.facing ~= dir do
    -- Pick the cheaper rotation direction.
    local diff = (dir - self.facing) % 4
    if diff == 1 then
      if not self:turn_left() then return false, "blocked turn" end
    elseif diff == 3 then
      if not self:turn_right() then return false, "blocked turn" end
    else
      if not self:turn_around() then return false, "blocked turn" end
    end
  end
  return true
end

-- Walk forward `n` cells, swinging through soft obstacles (entities,
-- crops, etc.) once if blocked. Returns false on hard obstacles so
-- the caller can decide whether to swing-mine or back off.
function Nav:walk(n, retry_swing)
  for _ = 1, n do
    local ok, err = self:forward()
    if not ok and retry_swing then
      pcall(self.r.swing, 3)                    -- side 3 = forward
      ok, err = self:forward()
    end
    if not ok then return false, err end
  end
  return true
end

-- Walk along z first then x. y movement is separate via goto_y.
function Nav:goto_xz(tx, tz, retry_swing)
  if tz ~= self.z then
    self:face(tz > self.z and 3 or 1)
    local ok, err = self:walk(math.abs(tz - self.z), retry_swing)
    if not ok then return false, err end
  end
  if tx ~= self.x then
    self:face(tx > self.x and 0 or 2)
    local ok, err = self:walk(math.abs(tx - self.x), retry_swing)
    if not ok then return false, err end
  end
  return true
end

function Nav:goto_y(ty)
  while self.y < ty do
    local ok, err = self:up(); if not ok then return false, err end
  end
  while self.y > ty do
    local ok, err = self:down(); if not ok then return false, err end
  end
  return true
end

function Nav:goto_xyz(tx, ty, tz, retry_swing)
  -- Climb to target altitude first if going up; if coming down, do
  -- horizontals first so we don't sink onto our chest before placing
  -- back its tools.
  if ty > self.y then
    if not self:goto_y(ty) then return false end
    return self:goto_xz(tx, tz, retry_swing)
  else
    local ok = self:goto_xz(tx, tz, retry_swing); if not ok then return false end
    return self:goto_y(ty)
  end
end

function Nav:home()
  local ok = self:goto_xyz(0, 0, 0, false); if not ok then return false end
  return self:face(0)
end

return M
