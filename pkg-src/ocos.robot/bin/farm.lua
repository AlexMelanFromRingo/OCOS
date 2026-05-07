-- /bin/farm.lua — autonomous wheat farmer.
--
-- Walks a W×H field, harvests mature crops, replants from slot 1.
-- Returns home when the inventory or energy gets low, drops harvest
-- into the chest below, refills seeds from the chest above, and
-- continues. Loops indefinitely until the user presses Ctrl-C.
--
-- Setup before running:
--
--   . Robot is sitting on the corner of the field, facing along the
--     long edge (let's call it +x). The field starts in the cell
--     directly in front of the robot.
--   . Below the robot's start tile: a chest for harvested wheat.
--   . Above the robot's start tile: a chest holding spare seeds.
--   . Slot 1 of the robot's inventory is pre-loaded with at least
--     one seed so the harvest-then-replant cycle has something to
--     plant on the very first tile.
--
-- Usage:
--   farm [-w <width>] [-h <height>] [--passes N | --forever]
--
--   -w / --width    cells along the forward axis (default 9)
--   -h / --height   cells along the right axis   (default 9)
--   --passes N      stop after N full passes (default: forever)
--   --forever       explicit alias
--
-- The traversal is the standard snake from lib/robot/path; because
-- nav.lua tracks coordinates absolutely the parity of W and H is
-- irrelevant — `nav:home()` always returns to (0, 0, 0) facing the
-- starting direction.

local args = ...
local nav_m  = require("lib.robot.nav")
local path_m = require("lib.robot.path")
local sched  = require("k.sched")

local function num(s, default) return tonumber(s) or default end

local W, H, passes = 9, 9, math.huge
local i = 1
while i <= #args do
  local a = args[i]
  if a == "-w" or a == "--width"  then W = num(args[i + 1], 9);  i = i + 2
  elseif a == "-h" or a == "--height" then H = num(args[i + 1], 9);  i = i + 2
  elseif a == "--passes"               then passes = num(args[i + 1], 1); i = i + 2
  elseif a == "--forever"              then passes = math.huge; i = i + 1
  else io.stderr:write("farm: unknown arg: " .. a .. "\n"); return 2
  end
end

local nav, err = nav_m.new()
if not nav then io.stderr:write("farm: " .. tostring(err) .. "\n"); return 1 end
local r = nav.r

-- Energy / inventory helpers.
local function energy_low()
  if not (computer.energy and computer.maxEnergy) then return false end
  return computer.energy() / computer.maxEnergy() < 0.15
end

local function inventory_full()
  -- Slot 1 reserved for seeds. Check 2..16 (or whatever robot.inventorySize returns).
  local size = (r.inventorySize and r.inventorySize()) or 16
  for s = 2, size do
    if (r.count(s) or 0) == 0 then return false end
  end
  return true
end

local function deposit_and_refuel()
  -- Robot is at (0, 0, 0) facing +x. Chest BELOW = harvest, chest
  -- ABOVE = seed reserve. Drop everything from slots 2..16 down,
  -- suck seeds up until slot 1 is comfortable.
  io.stdout:write("farm: depositing harvest, refilling seeds\n")
  local size = (r.inventorySize and r.inventorySize()) or 16
  for s = 2, size do
    local n = r.count(s) or 0
    if n > 0 then r.select(s); r.dropDown(n) end
  end
  r.select(1)
  while (r.count(1) or 0) < 32 do
    if not r.suckUp(64) then break end
  end
end

-- Try to harvest the cell directly below: swing if a block is there,
-- then place a seed back. Robot faces +x throughout the field walk.
local function work_cell()
  local has_block, kind = r.detectDown()
  if has_block and kind == "passable" then
    -- Sapling / wheat that swing reaches.
    pcall(r.swingDown)
  elseif has_block then
    pcall(r.swingDown)
  end
  -- Replant from slot 1. If slot 1 ran out, suck more from above on
  -- the next chest visit; until then, skip placing.
  r.select(1)
  if (r.count(1) or 0) > 0 then pcall(r.placeDown) end
end

-- Make sure we kick off with a seed in slot 1; otherwise the
-- trip-cost of the first pass is wasted.
do
  r.select(1)
  if (r.count(1) or 0) == 0 then
    io.stdout:write("farm: slot 1 empty — pulling seeds from above chest\n")
    pcall(r.suckUp, 32)
  end
end

local pass = 0
while pass < passes do
  pass = pass + 1
  io.stdout:write(string.format("farm: pass %d (W=%d H=%d)\n", pass, W, H))
  -- Step into the first cell of the field (in front of home). The
  -- snake iterator starts at (1,1) which is the cell in front of
  -- our (0,0) home tile, so goto (1, 0) lands us there.
  for x, z in path_m.snake(W, H) do
    if not nav:goto_xz(x, z - 1, true) then break end
    work_cell()
    if energy_low() or inventory_full() then
      io.stdout:write("farm: returning early (energy or inventory)\n")
      break
    end
    sched.sleep(0)                              -- yield to the scheduler
  end
  nav:home()
  deposit_and_refuel()
end

io.stdout:write("farm: done\n")
return 0
