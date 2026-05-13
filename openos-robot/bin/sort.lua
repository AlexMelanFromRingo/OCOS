-- sort.lua — chest-row sorter (OpenOS port).
--
-- Reads stacks from one input chest, routes each into a destination
-- chest in a row based on a Lua rule file.
--
-- Setup:
--   . Input chest BELOW the robot's start tile (0, 0).
--   . Output chests in a row in front: position N = cell (N, 0).
--   . `inventory_controller` upgrade required (so we can read item
--     names — robot.count alone doesn't tell us *what* is in a slot).
--   . Rule file is plain Lua:
--
--       return {
--         ["minecraft:wheat"]       = 1,
--         ["minecraft:wheat_seeds"] = 2,
--         ["minecraft:carrot"]      = 3,
--         _default                  = 4,    -- catch-all
--       }
--
--   Items with no rule and no _default get returned to the input chest.
--
-- Usage:
--   sort --rules /home/user/sort.lua [--passes N | --forever]

local args = {...}
local nav_m    = require("nav")
local component = require("component")

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
  local f, oerr = io.open(rules_path, "r")
  if not f then
    io.stderr:write("sort: cannot read " .. rules_path .. ": " .. tostring(oerr) .. "\n"); return 1
  end
  local src = f:read("*a"); f:close()
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

if not component.isAvailable("inventory_controller") then
  io.stderr:write("sort: no inventory_controller upgrade — can't read item names\n")
  return 1
end
local inv_ctrl = component.inventory_controller

local function inv_size() return r.inventorySize() end

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
  local stack = inv_ctrl.getStackInInternalSlot(slot)
  return stack and stack.name
end

local function deposit(slot, pos)
  if not nav:goto_xz(pos, 0, false) then return false end
  r.select(slot)
  return r.dropDown(64)
end

local pass = 0
while pass < passes do
  pass = pass + 1
  io.write(string.format("sort: pass %d\n", pass))
  while suck_one_stack() do
    if (r.count(inv_size()) or 0) > 0 then break end
  end
  for s = 1, inv_size() do
    if (r.count(s) or 0) > 0 then
      local nm = name_of(s) or ""
      local dest = rules[nm] or rules._default
      if dest then
        deposit(s, dest)
      else
        nav:goto_xz(0, 0, false)
        r.select(s); r.dropDown(64)
      end
      os.sleep(0)
    end
  end
  nav:home()
  os.sleep(2)
end

return 0
