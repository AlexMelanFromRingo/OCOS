-- OCOS /init.lua
-- Loaded by the EEPROM BIOS. Reads /sys/boot.lua via raw component calls
-- (the filesystem library is not loaded yet) and yields control to it.

local boot_addr = computer.getBootAddress()
local invoke = component.invoke

local function read_all(path)
  local handle, err = invoke(boot_addr, "open", path)
  if not handle then error("init: cannot open " .. path .. ": " .. tostring(err), 0) end
  local parts, chunk = {}, nil
  repeat
    chunk = invoke(boot_addr, "read", handle, math.maxinteger or math.huge)
    if chunk then parts[#parts + 1] = chunk end
  until not chunk
  invoke(boot_addr, "close", handle)
  return table.concat(parts)
end

local boot_src = read_all("/sys/boot.lua")
local boot_fn, load_err = load(boot_src, "=/sys/boot.lua", "t", _G)
if not boot_fn then error("init: cannot load /sys/boot.lua: " .. tostring(load_err), 0) end
return boot_fn(boot_addr, read_all)
