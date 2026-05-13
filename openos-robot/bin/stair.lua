-- stair.lua — descending 1-wide staircase (OpenOS port).
--
-- Each step: swing forward, walk forward, swing down, descend, swing
-- up for head-room. The result is a regular 45° staircase you can
-- walk through. Does not return home — leave a torch trail and walk
-- back yourself.
--
-- Setup:
--   . Robot at the top of the slope, facing into it.
--
-- Usage:
--   stair [-d DEPTH=32]

local args = {...}
local nav_m = require("nav")

local depth = 32
local i = 1
while i <= #args do
  local a = args[i]
  if a == "-d" or a == "--depth" then depth = tonumber(args[i + 1]) or 32; i = i + 2
  else io.stderr:write("stair: unknown arg: " .. a .. "\n"); return 2
  end
end

local nav, err = nav_m.new()
if not nav then io.stderr:write("stair: " .. tostring(err) .. "\n"); return 1 end
local r = nav.r

for step = 1, depth do
  pcall(r.swing)
  pcall(r.swingUp)
  if not nav:forward() then
    pcall(r.swing)
    if not nav:forward() then
      io.stderr:write("stair: blocked at step " .. step .. "\n"); break
    end
  end
  pcall(r.swingDown)
  if not nav:down() then
    io.stderr:write("stair: cannot descend at step " .. step .. "\n"); break
  end
  pcall(r.swingUp)
  os.sleep(0)
end

io.write("stair: done — descended " .. depth .. " steps\n")
return 0
