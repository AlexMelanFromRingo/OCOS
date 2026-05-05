-- /sys/lib/diag/trace.lua — append-mode debug trace shared by init,
-- sessiond, uid and other services. Picks the first writable mount
-- (preferring /mnt/<addr>/var/log/ over the boot fs so a read-only
-- boot disk doesn't black-hole the trace).
--
-- Usage:
--   local trace = require("lib.diag.trace").for_name("uid")
--   trace("compositor ready")

local M = {}

local vfs = require("k.vfs")

local function pick_dir()
  for _, m in ipairs(vfs.mounts()) do
    if m.prefix:sub(1, 5) == "/mnt/" then
      pcall(vfs.mkdir, m.prefix .. "/var")
      pcall(vfs.mkdir, m.prefix .. "/var/log")
      return m.prefix .. "/var/log"
    end
  end
  -- Fall back to boot fs if writable.
  pcall(vfs.mkdir, "/var")
  pcall(vfs.mkdir, "/var/log")
  return "/var/log"
end

function M.for_name(name)
  local path
  return function(msg)
    if not path then path = pick_dir() .. "/" .. name .. ".trace" end
    local h = vfs.open(path, "a")
    if not h then return end
    pcall(h.write, h, string.format("[%8.3f] %s\n", computer.uptime(), msg))
    pcall(h.close, h)
  end
end

return M
