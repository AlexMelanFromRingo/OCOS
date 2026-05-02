-- OCOS /init.lua
-- Loaded by the EEPROM BIOS. Reads /sys/boot.lua via raw component calls
-- (filesystem library is not loaded yet), executes it, then never returns.
--
-- Keep this file tiny. All real work happens in /sys/boot.lua.

local boot_addr = computer.getBootAddress()
local invoke = component.invoke

-- Earliest possible trace: write a single line to whatever writable fs we
-- find, BEFORE we even read /sys/boot.lua. Helps diagnose boot stalls.
do
  for addr in component.list("filesystem") do
    if addr ~= boot_addr then
      local oks, h = pcall(invoke, addr, "open", "/init.trace", "w")
      if oks and h then
        pcall(invoke, addr, "write", h,
          "init.lua running at " .. tostring(computer.uptime()) ..
          " on " .. addr:sub(1, 8) .. "\n")
        pcall(invoke, addr, "close", h)
        break
      end
    end
  end
end

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
