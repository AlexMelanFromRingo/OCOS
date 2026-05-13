-- tree.lua — sapling-row lumberjack (OpenOS port).
--
-- Walks a row of N sapling spots, chops anything that's grown into a
-- tree, replants a sapling, returns home to dump logs and refill
-- saplings. Loops until --passes runs out or Ctrl-C.
--
-- Setup:
--   . Robot hovers ONE tile above the row of dirt + saplings, facing
--     along the row. Origin (0, 0, 0) = above the first sapling.
--   . The spots extend along +x, spaced `--spacing` cells apart
--     (default 4 — keeps vanilla foliage from growing into neighbours).
--   . Chest below the start tile for logs / extra saplings.
--   . Slot 1: at least one sapling.
--
-- Usage:
--   tree [-n COUNT=4] [-s SPACING=4] [--passes N | --forever]

local args = {...}
local nav_m = require("nav")

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

local function inv_size() return r.inventorySize() end

local function inventory_full()
  for s = 2, inv_size() do
    if (r.count(s) or 0) == 0 then return false end
  end
  return true
end

local function deposit_and_refuel()
  io.write("tree: depositing logs, refilling saplings\n")
  for s = 2, inv_size() do
    if (r.count(s) or 0) > 0 then r.select(s); r.dropDown(64) end
  end
  r.select(1)
  while (r.count(1) or 0) < 16 do
    if not r.suckDown(16) then break end
  end
end

local function chop_up()
  local climbed = 0
  while true do
    if not r.detectUp() then break end
    pcall(r.swingUp)
    if not nav:up() then break end
    climbed = climbed + 1
    if climbed > 32 then break end
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
  -- If the block below us is still a sapling (matches slot 1), there
  -- is nothing to chop. Otherwise it's a log — step down onto it,
  -- break the stump, climb the trunk swinging up, descend, replant.
  if r.detectDown() then
    r.select(1)
    if r.compareDown() then return end             -- still sapling
  end
  if not nav:down() then return end
  pcall(r.swingDown)
  local climbed = chop_up()
  descend(climbed)
  r.select(1)
  if (r.count(1) or 0) > 0 then pcall(r.placeDown) end
  pcall(r.swingDown)
  nav:up()
end

local pass = 0
while pass < passes do
  pass = pass + 1
  io.write(string.format("tree: pass %d (count=%d spacing=%d)\n",
    pass, count, spacing))
  for k = 1, count do
    local x = (k - 1) * spacing
    if not nav:goto_xz(x, 0, false) then break end
    work_spot()
    if inventory_full() then
      io.write("tree: inventory full, returning early\n")
      break
    end
    os.sleep(0)
  end
  nav:home()
  deposit_and_refuel()
end
io.write("tree: done\n")
return 0
