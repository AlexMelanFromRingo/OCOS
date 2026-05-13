-- mine.lua — strip-miner / shallow quarry (OpenOS port).
--
-- Digs a rectangular W × L × D pit; surfaces after every layer to
-- dump. Use this for shallow pits (D ≤ 16); for deeper digs prefer
-- `quarry`, which only surfaces when it has to.
--
-- Setup:
--   . Robot on the corner of the dig area, facing along length.
--   . Chest below the start tile.
--   . Charger above (optional).
--
-- Usage:
--   mine [-w W=9] [-l L=9] [-d D=16]

local args = {...}
local nav_m  = require("nav")
local path_m = require("path")

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
  local size = r.inventorySize()
  for s = 1, size do if (r.count(s) or 0) == 0 then return false end end
  return true
end

local function deposit()
  io.write("mine: surfacing to dump\n")
  local home_y = nav.y
  nav:goto_y(0, true)
  nav:goto_xz(0, 0, true)
  nav:face(0)
  local size = r.inventorySize()
  for s = 1, size do
    if (r.count(s) or 0) > 0 then r.select(s); r.dropDown(64) end
  end
  nav:goto_y(home_y, true)
end

local function dig_cell()
  pcall(r.swingDown)
  pcall(r.swingUp)
end

for layer = 1, D do
  io.write(string.format("mine: layer %d / %d (y = %d)\n", layer, D, nav.y - 1))
  pcall(r.swingDown)
  if not nav:down() then
    io.stderr:write("mine: blocked descending — bedrock?\n"); break
  end
  for x, z in path_m.snake(W, L) do
    if not nav:goto_xz(x - 1, z - 1, true) then
      io.stderr:write("mine: blocked navigating to (" .. x .. "," .. z .. ")\n")
      break
    end
    dig_cell()
    if inventory_full() then deposit() end
    os.sleep(0)
  end
  nav:goto_xz(0, 0, true)
  nav:face(0)
end
nav:home(true)
io.write("mine: done\n")
return 0
