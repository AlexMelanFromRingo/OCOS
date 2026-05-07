-- /bin/tunnel.lua — straight 2-tall corridor digger.
--
-- Walks N cells forward, swinging both the cell in front and the cell
-- above it on every step so a 1×2 (1 wide, 2 tall) tunnel opens up.
-- Optionally drops a torch every K cells via slot 1 + use(side=above).
--
-- Setup:
--   . Robot stands at the tunnel mouth, facing into it.
--   . Slot 1: torches (optional; only used if --torch is passed).
--   . Below the start tile: a chest for cobble / drops if you want
--     auto-deposit when full.
--
-- Usage:
--   tunnel [-l LENGTH] [--torch K] [--no-deposit]
--     -l / --length   cells forward (default 32)
--     --torch K       place a torch every K cells (default off)
--     --no-deposit    skip the surface-and-dump phase (run forever)

local args = ...
local nav_m = require("lib.robot.nav")
local sched = require("k.sched")

local length, torch_every, deposit = 32, nil, true
local i = 1
while i <= #args do
  local a = args[i]
  if a == "-l" or a == "--length" then length = tonumber(args[i + 1]) or 32; i = i + 2
  elseif a == "--torch"               then torch_every = tonumber(args[i + 1]) or 8; i = i + 2
  elseif a == "--no-deposit"          then deposit = false; i = i + 1
  else io.stderr:write("tunnel: unknown arg: " .. a .. "\n"); return 2
  end
end

local nav, err = nav_m.new()
if not nav then io.stderr:write("tunnel: " .. tostring(err) .. "\n"); return 1 end
local r = nav.r

local function inv_size() return (r.inventorySize and r.inventorySize()) or 16 end

local function inventory_full()
  for s = 1, inv_size() do
    if (r.count(s) or 0) == 0 then return false end
  end
  return true
end

local function dump_at_home()
  io.stdout:write("tunnel: returning to dump\n")
  local saved_x, saved_z = nav.x, nav.z
  nav:goto_xz(0, 0, true)
  nav:face(0)
  for s = 2, inv_size() do
    if (r.count(s) or 0) > 0 then r.select(s); r.dropDown(64) end
  end
  -- Walk back to where we left off.
  nav:goto_xz(saved_x, saved_z, true)
  nav:face(0)
end

for step = 1, length do
  pcall(r.swing)                                    -- swing forward
  pcall(r.swingUp)                                  -- swing block above
  if not nav:forward() then
    -- Try once more after a swing — gravel sometimes refills the cell.
    pcall(r.swing)
    if not nav:forward() then
      io.stderr:write("tunnel: blocked at step " .. step .. "\n"); break
    end
  end
  if torch_every and step % torch_every == 0 then
    -- Place a torch on the wall to our left (block at left side).
    nav:turn_left()
    r.select(1)
    pcall(r.place)                                  -- place torch on the side wall
    nav:turn_right()
  end
  if deposit and inventory_full() then dump_at_home() end
  sched.sleep(0)
end

if deposit then dump_at_home() end
nav:home(true)
io.stdout:write("tunnel: done — " .. length .. " cells\n")
return 0
