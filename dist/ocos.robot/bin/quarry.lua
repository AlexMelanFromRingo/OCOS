-- /bin/quarry.lua — full 3D rectangular quarry.
--
-- Distinct from /bin/mine in that quarry digs a complete W×L×D box
-- and surfaces only when the inventory really fills, while mine
-- assumes a smaller depth and treats every layer like an independent
-- snake. quarry also breaks the cell ABOVE on each step so a robot
-- with a tier-1 inventory upgrade can clear a 1×1×Inf shaft on the
-- way down without being trapped under gravel.
--
-- Setup:
--   . Robot stands on the corner of the dig area at the surface,
--     facing into the box. (1, 1) is the cell in front of it; the
--     box extends to (W, L) and downward D layers.
--   . Below the start tile: a chest for output.
--   . Above (optional): a charger.
--
-- Usage:
--   quarry [-w W] [-l L] [-d D]
--     defaults 9 / 9 / 64
--
-- Even-W or even-L doesn't matter — lib.robot.nav drives by absolute
-- coordinates so the snake parity issue from naive step-counting
-- robots can't bite us here.

local args = ...
local nav_m  = require("lib.robot.nav")
local path_m = require("lib.robot.path")
local sched  = require("k.sched")

local W, L, D = 9, 9, 64
local i = 1
while i <= #args do
  local a = args[i]
  if a == "-w" or a == "--width"  then W = tonumber(args[i + 1]) or 9;  i = i + 2
  elseif a == "-l" or a == "--length" then L = tonumber(args[i + 1]) or 9;  i = i + 2
  elseif a == "-d" or a == "--depth"  then D = tonumber(args[i + 1]) or 64; i = i + 2
  else io.stderr:write("quarry: unknown arg: " .. a .. "\n"); return 2
  end
end

local nav, err = nav_m.new()
if not nav then io.stderr:write("quarry: " .. tostring(err) .. "\n"); return 1 end
local r = nav.r

local function inv_size() return (r.inventorySize and r.inventorySize()) or 16 end

local function inventory_full()
  for s = 1, inv_size() do
    if (r.count(s) or 0) == 0 then return false end
  end
  return true
end

local function energy_low()
  if not (computer.energy and computer.maxEnergy) then return false end
  return computer.energy() / computer.maxEnergy() < 0.1
end

local function surface_and_dump()
  io.stdout:write("quarry: surfacing to dump\n")
  local saved = nav:where()
  nav:goto_y(0)
  nav:goto_xz(0, 0, false)
  for s = 1, inv_size() do
    if (r.count(s) or 0) > 0 then r.select(s); r.dropDown(64) end
  end
  nav:goto_y(saved.y)
  nav:goto_xz(saved.x, saved.z, true)
end

local function dig_cell()
  pcall(r.swingDown)
  pcall(r.swingUp)
end

for layer = 1, D do
  io.stdout:write(string.format("quarry: layer %d / %d\n", layer, D))
  pcall(r.swingDown)
  if not nav:down() then
    io.stderr:write("quarry: blocked descending — bedrock?\n"); break
  end
  for x, z in path_m.snake(W, L) do
    if not nav:goto_xz(x - 1, z - 1, true) then break end
    dig_cell()
    if inventory_full() or energy_low() then
      surface_and_dump()
      if energy_low() then
        io.stdout:write("quarry: low energy — pausing for charge\n")
        while energy_low() do sched.sleep(5) end
      end
    end
    sched.sleep(0)
  end
  nav:goto_xz(0, 0, true)
  nav:face(0)
end

surface_and_dump()
nav:home()
io.stdout:write("quarry: done — " .. (W * L * D) .. " cells excavated\n")
return 0
