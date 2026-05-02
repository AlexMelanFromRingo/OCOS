-- /sys/k/panic.lua — last-resort error handler.
-- Tries to render a readable halt screen on whatever GPU we already bound.
-- Falls back to a `computer.beep` Morse-ish pattern if no GPU is bound.

local M = {}

local function find_gpu()
  local gpu_addr = component.list("gpu")()
  if not gpu_addr then return nil end
  return component.proxy(gpu_addr)
end

local function find_screen()
  return component.list("screen")()
end

function M.init()
  -- We hook into Lua errors implicitly: every kernel call site uses xpcall
  -- with M.handler. Nothing to do at init beyond returning.
end

local function dump_to_writable_fs(text)
  -- Try to write a panic dump onto any writable filesystem we can find via
  -- raw component.invoke (the VFS may not be functional during a panic).
  local boot_addr = _OCOS and _OCOS.boot_addr
  for addr in component.list("filesystem") do
    if addr ~= boot_addr then
      local ok, ro = pcall(component.invoke, addr, "isReadOnly")
      if ok and ro == false then
        local h = pcall(component.invoke, addr, "open", "/panic.log", "w") and component.invoke(addr, "open", "/panic.log", "w")
        if h then
          pcall(component.invoke, addr, "write", h, text)
          pcall(component.invoke, addr, "close", h)
          return addr
        end
      end
    end
  end
  return nil
end

function M.halt(reason, traceback)
  reason = tostring(reason or "unknown")
  traceback = tostring(traceback or debug.traceback("", 2))
  local dump = "OCOS PANIC\n" .. "reason: " .. reason .. "\n" .. traceback .. "\n"
  pcall(dump_to_writable_fs, dump)
  local gpu = find_gpu()
  if gpu then
    pcall(function()
      local screen = find_screen()
      if screen then gpu.bind(screen, false) end
      local w, h = gpu.getResolution()
      gpu.setBackground(0x000040)
      gpu.setForeground(0xFFFFFF)
      gpu.fill(1, 1, w, h, " ")
      gpu.set(2, 2, "OCOS PANIC")
      gpu.set(2, 4, "reason: " .. reason:sub(1, w - 12))
      gpu.set(2, 6, "traceback:")
      local y = 7
      for line in traceback:gmatch("[^\n]+") do
        if y > h - 2 then break end
        gpu.set(2, y, line:sub(1, w - 4))
        y = y + 1
      end
      gpu.set(2, h - 1, "system halted. press the power button to shut down.")
    end)
  else
    -- 3 short, 3 long, 3 short — SOS
    for _, d in ipairs({ 0.1, 0.1, 0.1, 0.4, 0.4, 0.4, 0.1, 0.1, 0.1 }) do
      pcall(computer.beep, 1000, d)
    end
  end
  while true do computer.pullSignal(60) end
end

function M.handler(err)
  -- Used as the second arg to xpcall. Returns the error message *plus* a
  -- traceback so callers can show or log both.
  return tostring(err) .. "\n" .. debug.traceback("", 2)
end

return M
