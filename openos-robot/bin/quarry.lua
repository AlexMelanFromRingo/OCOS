-- quarry.lua — full 3D rectangular quarry (OpenOS port).
--
-- Digs a W×L×D box and surfaces only when the inventory fills or the
-- energy reserve gets thin. Even-W / even-L doesn't strand the robot
-- because nav drives by absolute coordinates.
--
-- Setup:
--   . Robot on the corner of the dig area, facing into the box.
--   . Chest below the start tile for output.
--   . Charger above (optional but recommended for D > 16).
--
-- Usage:
--   quarry [-w W=9] [-l L=9] [-d D=64]
--
-- Energy budgeting uses nav:distance_home() × MOVE_COST + RESERVE so
-- a deep dig doesn't strand the robot at y = -60 with too little juice
-- to climb out. surface_and_dump uses nav:goto_y(0, true) so any
-- cobble that grew in the chimney (from lava + water nearby) can be
-- broken on the way up.

local args = {...}
local nav_m  = require("nav")
local path_m = require("path")
local computer = require("computer")

local W, L, D = 9, 9, 64
local MOVE_COST = 60
local RESERVE   = 500

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

local function inv_size() return r.inventorySize() end

local function inventory_full()
  for s = 1, inv_size() do
    if (r.count(s) or 0) == 0 then return false end
  end
  return true
end

local function need_to_surface()
  local needed = nav:distance_home() * MOVE_COST + RESERVE
  return computer.energy() < needed
end

local function wait_for_charge()
  while computer.energy() / computer.maxEnergy() < 0.9 do
    os.sleep(5)
  end
end

local function surface_and_dump()
  io.write("quarry: surfacing to dump\n")
  local saved = nav:where()
  nav:goto_y(0, true)
  nav:goto_xz(0, 0, true)
  for s = 1, inv_size() do
    if (r.count(s) or 0) > 0 then r.select(s); r.dropDown(64) end
  end
  if need_to_surface() then
    io.write("quarry: low energy at home — waiting for charger\n")
    wait_for_charge()
  end
  nav:goto_y(saved.y, true)
  nav:goto_xz(saved.x, saved.z, true)
end

local function dig_cell()
  pcall(r.swingDown)
  pcall(r.swingUp)
end

for layer = 1, D do
  io.write(string.format("quarry: layer %d / %d\n", layer, D))
  pcall(r.swingDown)
  if not nav:down() then
    io.stderr:write("quarry: blocked descending — bedrock?\n"); break
  end
  for x, z in path_m.snake(W, L) do
    if not nav:goto_xz(x - 1, z - 1, true) then break end
    dig_cell()
    if inventory_full() or need_to_surface() then surface_and_dump() end
    os.sleep(0)
  end
  nav:goto_xz(0, 0, true)
  nav:face(0)
end

surface_and_dump()
nav:home(true)
io.write("quarry: done — " .. (W * L * D) .. " cells excavated\n")
return 0
