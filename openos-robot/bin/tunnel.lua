-- tunnel.lua — straight 1×2 corridor digger (OpenOS port).
--
-- Walks N cells forward, swinging the front and the head-room cell
-- on every step. Optional torch placement on the left wall every K
-- cells (slot 1 holds the torches).
--
-- Setup:
--   . Robot at the tunnel mouth, facing into it.
--   . Slot 1: torches if you pass --torch.
--   . Chest below the start tile for auto-deposit.
--
-- Usage:
--   tunnel [-l LENGTH=32] [--torch K] [--no-deposit]

local args = {...}
local nav_m = require("nav")

local length, torch_every, deposit = 32, nil, true
local i = 1
while i <= #args do
  local a = args[i]
  if a == "-l" or a == "--length" then length = tonumber(args[i + 1]) or 32; i = i + 2
  elseif a == "--torch"           then torch_every = tonumber(args[i + 1]) or 8; i = i + 2
  elseif a == "--no-deposit"      then deposit = false; i = i + 1
  else io.stderr:write("tunnel: unknown arg: " .. a .. "\n"); return 2
  end
end

local nav, err = nav_m.new()
if not nav then io.stderr:write("tunnel: " .. tostring(err) .. "\n"); return 1 end
local r = nav.r

local function inv_size() return r.inventorySize() end

local function inventory_full()
  for s = 1, inv_size() do
    if (r.count(s) or 0) == 0 then return false end
  end
  return true
end

local function dump_at_home()
  io.write("tunnel: returning to dump\n")
  local saved_x, saved_z = nav.x, nav.z
  nav:goto_xz(0, 0, true)
  nav:face(0)
  for s = 2, inv_size() do
    if (r.count(s) or 0) > 0 then r.select(s); r.dropDown(64) end
  end
  nav:goto_xz(saved_x, saved_z, true)
  nav:face(0)
end

for step = 1, length do
  pcall(r.swing)
  pcall(r.swingUp)
  if not nav:forward() then
    pcall(r.swing)
    if not nav:forward() then
      io.stderr:write("tunnel: blocked at step " .. step .. "\n"); break
    end
  end
  if torch_every and step % torch_every == 0 then
    nav:turn_left()
    r.select(1)
    pcall(r.place)
    nav:turn_right()
  end
  if deposit and inventory_full() then dump_at_home() end
  os.sleep(0)
end

if deposit then dump_at_home() end
nav:home(true)
io.write("tunnel: done — " .. length .. " cells\n")
return 0
