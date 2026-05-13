-- nav.lua — coordinate-tracking robot navigation (OpenOS port).
--
-- Ported from OCOS's lib/robot/nav.lua. Two differences vs the OCOS
-- original:
--
--   * Uses the OpenOS `robot` lib for move/swing/turn. On OpenOS the
--     raw component.robot only exposes move(side) / turn(clockwise) /
--     swing(side); the high-level forward()/turnLeft()/swingUp()
--     names live in /lib/robot.lua. OCOS could call them directly on
--     _G.component.robot only because OCVM and OCOS layered a shim;
--     real OC robots don't, so this port goes through the standard
--     `robot` library.
--   * `require("robot")` instead of polling _G.component.
--
-- Everything else — facing model, retry_swing on vertical moves,
-- distance_home() — is unchanged.
--
-- Conventions:
--   * Robot starts at (0, 0, 0) facing FORWARD (= +x).
--   * Facing: 0 = +x (forward), 1 = -z (left), 2 = -x (back),
--     3 = +z (right). turn_left increments facing mod 4.
--
-- Public API:
--   nav.new()                                  build a fresh navigator
--   n:forward() / back() / up() / down()       move + update coords
--   n:turn_left() / turn_right() / turn_around()
--   n:face(dir)                                turn to dir 0..3
--   n:walk(n, retry_swing)
--   n:goto_xz(x, z, retry_swing)
--   n:goto_y(y, retry_swing)                   may swing up/down on blocks
--   n:goto_xyz(x, y, z, retry_swing)
--   n:home(retry_swing)                        goto (0,0,0) facing 0
--   n:where()                                  {x, y, z, facing}
--   n:distance_home()                          Manhattan steps back to origin

local M = {}

local robot = require("robot")

local Nav = {}
Nav.__index = Nav

function M.new()
  return setmetatable({
    r       = robot,
    x       = 0, y = 0, z = 0,
    facing  = 0,                                -- 0=+x, 1=-z, 2=-x, 3=+z
  }, Nav)
end

function Nav:where()
  return { x = self.x, y = self.y, z = self.z, facing = self.facing }
end

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

function Nav:walk(n, retry_swing)
  for _ = 1, n do
    local ok, err = self:forward()
    if not ok and retry_swing then
      pcall(self.r.swing)                         -- robot.swing() = front
      ok, err = self:forward()
    end
    if not ok then return false, err end
  end
  return true
end

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

-- Vertical retries cap so a robot doesn't wedge itself forever
-- against a regenerating cobble fountain (lava + water mixing in the
-- column above its return path).
local MAX_VERTICAL_SWINGS = 8
function Nav:goto_y(ty, retry_swing)
  while self.y < ty do
    local ok, err = self:up()
    if not ok and retry_swing then
      for _ = 1, MAX_VERTICAL_SWINGS do
        pcall(self.r.swingUp)
        ok, err = self:up()
        if ok then break end
      end
    end
    if not ok then return false, err end
  end
  while self.y > ty do
    local ok, err = self:down()
    if not ok and retry_swing then
      for _ = 1, MAX_VERTICAL_SWINGS do
        pcall(self.r.swingDown)
        ok, err = self:down()
        if ok then break end
      end
    end
    if not ok then return false, err end
  end
  return true
end

function Nav:goto_xyz(tx, ty, tz, retry_swing)
  if ty > self.y then
    if not self:goto_y(ty, retry_swing) then return false end
    return self:goto_xz(tx, tz, retry_swing)
  else
    local ok = self:goto_xz(tx, tz, retry_swing); if not ok then return false end
    return self:goto_y(ty, retry_swing)
  end
end

function Nav:home(retry_swing)
  local ok = self:goto_xyz(0, 0, 0, retry_swing); if not ok then return false end
  return self:face(0)
end

function Nav:distance_home()
  return math.abs(self.x) + math.abs(self.y) + math.abs(self.z)
end

return M
