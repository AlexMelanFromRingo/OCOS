-- /bin/fill.lua — place blocks across a W×H field below the robot.
--
-- Walks the field in a snake (works for any W and H) and places one
-- block from slot 1 down on each cell. Useful for foundations,
-- patching mined-out floors, or laying farmland (with --use instead
-- of --place to right-click hoes onto dirt).
--
-- Setup:
--   . Robot stands at the corner of the area, facing along the long
--     axis. The first cell to fill is directly in front.
--   . Slot 1: blocks (or tool, with --use).
--
-- Usage:
--   fill [-w W] [-h H] [--up | --down] [--use]
--     -w / --width    cells along forward (default 8)
--     -h / --height   cells along right   (default 8)
--     --up            place ABOVE each cell instead of below
--     --use           right-click instead of place (e.g. hoe → till)

local args = ...
local nav_m  = require("lib.robot.nav")
local path_m = require("lib.robot.path")
local sched  = require("k.sched")

local W, H = 8, 8
local mode = "down"           -- "down" | "up"
local action = "place"        -- "place" | "use"
local i = 1
while i <= #args do
  local a = args[i]
  if a == "-w" or a == "--width"  then W = tonumber(args[i + 1]) or 8; i = i + 2
  elseif a == "-h" or a == "--height" then H = tonumber(args[i + 1]) or 8; i = i + 2
  elseif a == "--up"                  then mode = "up"; i = i + 1
  elseif a == "--down"                then mode = "down"; i = i + 1
  elseif a == "--use"                 then action = "use"; i = i + 1
  else io.stderr:write("fill: unknown arg: " .. a .. "\n"); return 2
  end
end

local nav, err = nav_m.new()
if not nav then io.stderr:write("fill: " .. tostring(err) .. "\n"); return 1 end
local r = nav.r

local function do_action()
  r.select(1)
  if action == "use" then
    if mode == "up"   then return r.use(1)  end       -- side 1 = top
    return r.use(0)                                    -- side 0 = bottom
  end
  if mode == "up"   then return r.placeUp() end
  return r.placeDown()
end

for x, z in path_m.snake(W, H) do
  if not nav:goto_xz(x, z - 1, true) then break end
  do_action()
  sched.sleep(0)
end
nav:home()
io.stdout:write("fill: done — " .. (W * H) .. " cells\n")
return 0
