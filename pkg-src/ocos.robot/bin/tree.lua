-- /bin/tree.lua — autonomous tree farmer.
--
-- Walks a row of N sapling spots, chops anything that's grown into
-- a tree, replants a sapling, returns home to dump logs and refill
-- saplings. Loops until the user presses Ctrl-C or --passes runs out.
--
-- Setup:
--
--   . Robot stands one tile in front of the row, facing along it.
--     The first sapling spot is the cell directly in front of the
--     robot, then they extend along +x with `spacing` cells between
--     each tree (recommended: spacing >= 4 for vanilla saplings so
--     foliage doesn't grow into neighbours).
--   . Below the start tile: a chest for logs / saplings.
--   . Slot 1: at least one sapling so the first cycle can replant.
--
-- Usage:
--   tree [-n COUNT] [-s SPACING] [--passes N | --forever]
--     -n / --count     number of sapling spots (default 4)
--     -s / --spacing   cells between spots (default 4)
--
-- Tree felling: when the robot arrives at a spot, it looks UP. If
-- there's a block above (= tree trunk), it climbs the trunk swinging
-- as it goes until the block above goes away (top of the tree),
-- then descends, then replants.

local args = ...
local nav_m = require("lib.robot.nav")
local sched = require("k.sched")

local count, spacing, passes = 4, 4, math.huge
local i = 1
while i <= #args do
  local a = args[i]
  if a == "-n" or a == "--count"   then count   = tonumber(args[i + 1]) or 4; i = i + 2
  elseif a == "-s" or a == "--spacing" then spacing = tonumber(args[i + 1]) or 4; i = i + 2
  elseif a == "--passes"               then passes  = tonumber(args[i + 1]) or 1; i = i + 2
  elseif a == "--forever"              then passes  = math.huge; i = i + 1
  else io.stderr:write("tree: unknown arg: " .. a .. "\n"); return 2
  end
end

local nav, err = nav_m.new()
if not nav then io.stderr:write("tree: " .. tostring(err) .. "\n"); return 1 end
local r = nav.r

local function inv_size() return (r.inventorySize and r.inventorySize()) or 16 end

local function inventory_full()
  for s = 2, inv_size() do
    if (r.count(s) or 0) == 0 then return false end
  end
  return true
end

local function deposit_and_refuel()
  io.stdout:write("tree: depositing logs, refilling saplings\n")
  for s = 2, inv_size() do
    if (r.count(s) or 0) > 0 then r.select(s); r.dropDown(64) end
  end
  r.select(1)
  while (r.count(1) or 0) < 16 do
    if not r.suckDown(16) then break end
  end
end

-- Climb the trunk: while there's a block above, swing up and ascend.
-- Returns the height we ended up at (so we can descend the same).
local function chop_up()
  local climbed = 0
  while true do
    local has_block = r.detectUp()
    if not has_block then break end
    pcall(r.swingUp)
    if not nav:up() then break end
    climbed = climbed + 1
    if climbed > 32 then break end                -- runaway guard
  end
  return climbed
end

local function descend(n)
  for _ = 1, n do
    if not nav:down() then return false end
  end
  return true
end

local function work_spot()
  -- Stand-on tile is `spot_x, 0`. The sapling sits at `spot_x, 0`
  -- (i.e., on the tile we're standing on, ground level). The trunk
  -- grows upward into the air above; we walk forward to be ABOVE
  -- the sapling? Actually no — the robot is on the air block above
  -- the dirt; the sapling block is at our y level. We swing FORWARD
  -- to break it. Hmm — too fiddly. Simpler convention:
  --
  --   . The dirt + sapling are at y = 0; robot stands at y = 1
  --     directly above the sapling and faces +x.
  --   . On arrival the robot detectsDown. If the block below is a
  --     log (tree grew), the trunk extends upward; we climb +
  --     swing until clear, then descend, then placeDown a sapling.
  --
  -- For this we offset by +1 in y when navigating. Hand-build the
  -- offset here.
  local has_block_below = r.detectDown()
  if has_block_below then
    -- Either dirt (sapling didn't grow yet) or log (grown).
    -- Try to compare with what's in slot 1 (sapling). If equal,
    -- still a sapling — leave it. Otherwise treat as log.
    r.select(1)
    if r.compareDown() then return end           -- still sapling, no work
  end
  -- Chop: trunk extends upward from below us. We need to be ON the
  -- log, so step down once.
  if not nav:down() then return end
  pcall(r.swingDown)                              -- break stump under us
  local climbed = chop_up()
  descend(climbed)
  -- Replant. We're standing on dirt now; placeDown puts sapling.
  r.select(1)
  if (r.count(1) or 0) > 0 then pcall(r.placeDown) end
  -- Step back up to the air-tile flight level.
  pcall(r.swingDown)                              -- shouldn't be anything, just safety
  nav:up()
end

-- Initial seed-up: get the robot to flight-level (1 tile above the
-- dirt row). The user sets up the robot at flight-level directly,
-- which is the simplest contract — origin (0, 0, 0) is *the cell
-- above the first sapling*.

local pass = 0
while pass < passes do
  pass = pass + 1
  io.stdout:write(string.format("tree: pass %d (count=%d spacing=%d)\n",
    pass, count, spacing))
  for k = 1, count do
    local x = (k - 1) * spacing
    if not nav:goto_xz(x, 0, false) then break end
    work_spot()
    if inventory_full() then
      io.stdout:write("tree: inventory full, returning early\n")
      break
    end
    sched.sleep(0)
  end
  nav:home()
  deposit_and_refuel()
end
io.stdout:write("tree: done\n")
return 0
