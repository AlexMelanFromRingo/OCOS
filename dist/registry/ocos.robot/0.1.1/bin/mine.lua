-- /bin/mine.lua — quarry / strip-miner.
--
-- Digs a rectangular pit `width × length` cells across and `depth`
-- layers deep, returning to home after every layer to dump cobble
-- and recharge. Standard quarry pattern: snake the layer, drop down
-- one block at the corner the snake ends on, snake back, descend,
-- repeat.
--
-- Setup:
--
--   . Robot stands on the corner of the dig area, facing along the
--     length axis (cell (1, 1) is right in front of it).
--   . Below: a chest for cobble / ores.
--   . Above: a charger or spare-tools chest (optional).
--
-- Usage:
--   mine [-w W] [-l L] [-d D]
--     -w / --width    cells across (default 9)
--     -l / --length   cells forward (default 9)
--     -d / --depth    layers (default 16)
--
-- The naive snake of lib.robot.path works for any W and L because
-- nav.lua tracks coordinates absolutely; even-sized fields don't
-- strand the robot at the wrong corner.

local args = ...
local nav_m  = require("lib.robot.nav")
local path_m = require("lib.robot.path")
local sched  = require("k.sched")

local W, L, D = 9, 9, 16
local i = 1
while i <= #args do
  local a = args[i]
  if a == "-w" or a == "--width"  then W = tonumber(args[i + 1]) or 9;  i = i + 2
  elseif a == "-l" or a == "--length" then L = tonumber(args[i + 1]) or 9;  i = i + 2
  elseif a == "-d" or a == "--depth"  then D = tonumber(args[i + 1]) or 16; i = i + 2
  else io.stderr:write("mine: unknown arg: " .. a .. "\n"); return 2
  end
end

local nav, err = nav_m.new()
if not nav then io.stderr:write("mine: " .. tostring(err) .. "\n"); return 1 end
local r = nav.r

local function inventory_full()
  local size = (r.inventorySize and r.inventorySize()) or 16
  for s = 1, size do if (r.count(s) or 0) == 0 then return false end end
  return true
end

local function deposit()
  io.stdout:write("mine: surfacing to dump\n")
  local home_y = nav.y
  nav:goto_y(0, true)                                -- break through cobble if any
  nav:goto_xz(0, 0, true)
  nav:face(0)
  local size = (r.inventorySize and r.inventorySize()) or 16
  for s = 1, size do
    if (r.count(s) or 0) > 0 then r.select(s); r.dropDown(64) end
  end
  nav:goto_y(home_y, true)
end

local function dig_cell()
  -- Swing forward / down / up to clear all 3 dimensions of the cell
  -- the robot just landed on.
  pcall(r.swingDown)
  pcall(r.swingUp)
end

for layer = 1, D do
  io.stdout:write(string.format("mine: layer %d / %d (y = %d)\n", layer, D, nav.y - 1))
  -- Drop one level. Swing first so we don't bonk our head on cobble.
  pcall(r.swingDown)
  if not nav:down() then
    io.stderr:write("mine: blocked descending — bedrock?\n"); break
  end
  -- Snake the layer.
  for x, z in path_m.snake(W, L) do
    -- Walk into the cell. swingForward in case there's a wall.
    if not nav:goto_xz(x - 1, z - 1, true) then
      io.stderr:write("mine: blocked navigating to (" .. x .. "," .. z .. ")\n")
      break
    end
    dig_cell()
    if inventory_full() then deposit() end
    sched.sleep(0)
  end
  nav:goto_xz(0, 0, true)
  nav:face(0)
end
nav:home(true)
io.stdout:write("mine: done\n")
return 0
