-- farm.lua — autonomous wheat farmer (OpenOS port).
--
-- Walks a W×H field, harvests mature crops, replants from slot 1.
-- Returns home when the inventory or energy gets low, drops harvest
-- into the chest below, refills seeds from the chest above, and
-- continues. Loops indefinitely until the user presses Ctrl-C.
--
-- Setup before running:
--   . Robot sits on the corner of the field, facing along the long
--     edge (= +x). The field starts in the cell directly in front.
--   . Below the start tile: a chest for harvested wheat.
--   . Above the start tile: a chest holding spare seeds.
--   . Slot 1 pre-loaded with at least one seed so the
--     harvest-then-replant cycle has something to plant on tile 1.
--
-- Usage:
--   farm [-w W] [-h H] [--passes N | --forever]

local args = {...}
local nav_m   = require("nav")
local path_m  = require("path")
local computer = require("computer")

local function num(s, default) return tonumber(s) or default end

local W, H, passes = 9, 9, math.huge
local i = 1
while i <= #args do
  local a = args[i]
  if a == "-w" or a == "--width"  then W = num(args[i + 1], 9); i = i + 2
  elseif a == "-h" or a == "--height" then H = num(args[i + 1], 9); i = i + 2
  elseif a == "--passes" then passes = num(args[i + 1], 1); i = i + 2
  elseif a == "--forever" then passes = math.huge; i = i + 1
  else io.stderr:write("farm: unknown arg: " .. a .. "\n"); return 2
  end
end

local nav, err = nav_m.new()
if not nav then io.stderr:write("farm: " .. tostring(err) .. "\n"); return 1 end
local r = nav.r

local function energy_low()
  return computer.energy() / computer.maxEnergy() < 0.15
end

local function inventory_full()
  local size = r.inventorySize()
  for s = 2, size do
    if (r.count(s) or 0) == 0 then return false end
  end
  return true
end

local function deposit_and_refuel()
  io.write("farm: depositing harvest, refilling seeds\n")
  local size = r.inventorySize()
  for s = 2, size do
    local n = r.count(s) or 0
    if n > 0 then r.select(s); r.dropDown(n) end
  end
  r.select(1)
  while (r.count(1) or 0) < 32 do
    if not r.suckUp(64) then break end
  end
end

local function work_cell()
  local has_block, kind = r.detectDown()
  if has_block then pcall(r.swingDown) end
  r.select(1)
  if (r.count(1) or 0) > 0 then pcall(r.placeDown) end
end

do
  r.select(1)
  if (r.count(1) or 0) == 0 then
    io.write("farm: slot 1 empty — pulling seeds from above chest\n")
    pcall(r.suckUp, 32)
  end
end

local pass = 0
while pass < passes do
  pass = pass + 1
  io.write(string.format("farm: pass %d (W=%d H=%d)\n", pass, W, H))
  for x, z in path_m.snake(W, H) do
    if not nav:goto_xz(x, z - 1, true) then break end
    work_cell()
    if energy_low() or inventory_full() then
      io.write("farm: returning early (energy or inventory)\n")
      break
    end
    os.sleep(0)
  end
  nav:home()
  deposit_and_refuel()
end

io.write("farm: done\n")
return 0
