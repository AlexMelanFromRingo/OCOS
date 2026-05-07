-- /bin/sort.lua — chest-row sorter for a robot.
--
-- Reads items from one input chest and routes each stack to a
-- destination chest based on a Lua rule file. The robot drives along
-- a row of output chests, dropping each item into the chest that
-- matches the rule for that item's name.
--
-- Setup:
--
--   . Input chest sits BELOW the robot's start tile (0, 0).
--   . Output chests run along the row in front of the robot:
--     position 1 = cell (1, 0), position 2 = cell (2, 0), …
--   . A rule file at the path passed via --rules maps item names
--     to chest indices. Format:
--
--       return {
--         ["minecraft:wheat"]      = 1,
--         ["minecraft:wheat_seeds"] = 2,
--         ["minecraft:carrot"]     = 3,
--         _default                  = 4,    -- catch-all
--       }
--
-- The rule file is plain Lua — load() in a sandboxed env. Items not
-- in the table fall through to `_default`; if `_default` is nil they
-- get returned to the input chest.
--
-- Usage:
--   sort --rules /home/alex/sort.lua [--passes N | --forever]
--
-- Requires the `inventory_controller` upgrade so we can ask each slot
-- for its item name (robot.count alone doesn't tell us *what* is in
-- there).

local args = ...
local nav_m = require("lib.robot.nav")
local sched = require("k.sched")
local vfs   = require("k.vfs")

local rules_path
local passes = math.huge
local i = 1
while i <= #args do
  local a = args[i]
  if a == "--rules"   then rules_path = args[i + 1]; i = i + 2
  elseif a == "--passes"  then passes = tonumber(args[i + 1]) or 1; i = i + 2
  elseif a == "--forever" then passes = math.huge; i = i + 1
  else io.stderr:write("sort: unknown arg: " .. a .. "\n"); return 2
  end
end
if not rules_path then
  io.stderr:write("usage: sort --rules <path> [--passes N | --forever]\n"); return 2
end

local rules
do
  local src = vfs.read_all(rules_path)
  if not src then io.stderr:write("sort: cannot read " .. rules_path .. "\n"); return 1 end
  local fn, lerr = load(src, "=" .. rules_path, "t", {})
  if not fn then io.stderr:write("sort: " .. tostring(lerr) .. "\n"); return 1 end
  local ok, t = pcall(fn)
  if not ok or type(t) ~= "table" then
    io.stderr:write("sort: rules file must return a table\n"); return 1
  end
  rules = t
end

local nav, err = nav_m.new()
if not nav then io.stderr:write("sort: " .. tostring(err) .. "\n"); return 1 end
local r = nav.r

-- Inventory controller lookup. Without it we can't read item names.
local inv_ctrl
if _G.component then
  if _G.component.inventory_controller then inv_ctrl = _G.component.inventory_controller
  elseif _G.component.list then
    local addr = _G.component.list("inventory_controller")()
    if addr then inv_ctrl = _G.component.proxy(addr) end
  end
end
if not inv_ctrl then
  io.stderr:write("sort: no inventory_controller upgrade — can't read item names\n")
  return 1
end

local function inv_size() return (r.inventorySize and r.inventorySize()) or 16 end

-- Pull a stack from the chest below into the first empty slot. Returns
-- the slot we wrote into, or nil if input chest is empty or robot full.
local function suck_one_stack()
  local size = inv_size()
  for s = 1, size do
    if (r.count(s) or 0) == 0 then
      r.select(s)
      if r.suckDown(64) then return s end
      return nil
    end
  end
  return nil
end

local function name_of(slot)
  -- inventory_controller.getStackInInternalSlot returns a table with
  -- .name (e.g., "minecraft:wheat") or nil for empty slots.
  local stack = inv_ctrl.getStackInInternalSlot(slot)
  return stack and stack.name
end

-- Drop everything in `slot` into the chest at position `pos` along
-- the row. nav:goto_xz(pos, 0) lands the robot ON the chest's tile,
-- so we drop sideways. Convention: chest sits at (pos, 0), robot
-- arrives there facing +x — drop down lands inside the chest below.
-- (Same chest layout as farm.)
local function deposit(slot, pos)
  if not nav:goto_xz(pos, 0, false) then return false end
  r.select(slot)
  return r.dropDown(64)
end

local pass = 0
while pass < passes do
  pass = pass + 1
  io.stdout:write(string.format("sort: pass %d\n", pass))
  -- Fill the robot from the input chest as much as possible.
  while suck_one_stack() do
    if (r.count(inv_size()) or 0) > 0 then break end
  end
  -- Walk slot by slot, route each to its rule destination.
  for s = 1, inv_size() do
    if (r.count(s) or 0) > 0 then
      local nm = name_of(s) or ""
      local dest = rules[nm] or rules._default
      if dest then
        deposit(s, dest)
      else
        -- No rule and no default — return to input chest.
        nav:goto_xz(0, 0, false)
        r.select(s); r.dropDown(64)
      end
      sched.sleep(0)
    end
  end
  nav:home()
  -- If input chest is empty, sleep a bit before next pass so we
  -- don't spin the CPU on an empty hopper.
  sched.sleep(2)
end

return 0
