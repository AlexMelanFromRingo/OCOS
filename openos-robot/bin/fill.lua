-- fill.lua — place blocks across a W×H field (OpenOS port).
--
-- Walks the field in a snake (works for any W × H, even sizes too)
-- and places / uses slot 1 against the floor or ceiling of each cell.
--
-- Setup:
--   . Robot at the corner of the area, facing along the long axis.
--     The first cell is directly in front.
--   . Slot 1: blocks (or a tool, with --use; e.g. hoe → till dirt).
--
-- Usage:
--   fill [-w W=8] [-h H=8] [--up | --down] [--use]

local args = {...}
local nav_m  = require("nav")
local path_m = require("path")

local W, H = 8, 8
local mode = "down"           -- "down" | "up"
local action = "place"        -- "place" | "use"
local i = 1
while i <= #args do
  local a = args[i]
  if a == "-w" or a == "--width"  then W = tonumber(args[i + 1]) or 8; i = i + 2
  elseif a == "-h" or a == "--height" then H = tonumber(args[i + 1]) or 8; i = i + 2
  elseif a == "--up"   then mode = "up"; i = i + 1
  elseif a == "--down" then mode = "down"; i = i + 1
  elseif a == "--use"  then action = "use"; i = i + 1
  else io.stderr:write("fill: unknown arg: " .. a .. "\n"); return 2
  end
end

local nav, err = nav_m.new()
if not nav then io.stderr:write("fill: " .. tostring(err) .. "\n"); return 1 end
local r = nav.r

local function do_action()
  r.select(1)
  if action == "use" then
    if mode == "up" then return r.useUp() end
    return r.useDown()
  end
  if mode == "up" then return r.placeUp() end
  return r.placeDown()
end

for x, z in path_m.snake(W, H) do
  if not nav:goto_xz(x, z - 1, true) then break end
  do_action()
  os.sleep(0)
end
nav:home()
io.write("fill: done — " .. (W * H) .. " cells\n")
return 0
