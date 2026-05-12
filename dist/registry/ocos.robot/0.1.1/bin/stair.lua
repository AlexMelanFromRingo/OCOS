-- /bin/stair.lua — descending staircase to a target depth.
--
-- Each step: swing forward, walk forward (now on broken-out cell),
-- swing down + descend (so the floor under us drops one), swing up
-- so we have head-room. Repeat. The result is a 1-wide staircase
-- going down at 45° that you can walk through normally.
--
-- Setup:
--   . Robot stands at the top of where you want the staircase to
--     start, facing into the slope.
--
-- Usage:
--   stair [-d DEPTH]
--     -d / --depth    steps down (default 32)

local args = ...
local nav_m = require("lib.robot.nav")
local sched = require("k.sched")

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
  pcall(r.swing)                                    -- block in front of us
  pcall(r.swingUp)                                  -- head-room above
  if not nav:forward() then
    pcall(r.swing); if not nav:forward() then
      io.stderr:write("stair: blocked at step " .. step .. "\n"); break
    end
  end
  pcall(r.swingDown)                                -- next step's floor
  if not nav:down() then
    io.stderr:write("stair: cannot descend at step " .. step .. "\n"); break
  end
  pcall(r.swingUp)                                  -- new head-room
  sched.sleep(0)
end

io.stdout:write("stair: done — descended " .. depth .. " steps\n")
return 0
