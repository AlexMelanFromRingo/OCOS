-- /sys/drv/fs.lua — auto-mount external filesystems at /mnt/<addr-prefix>/.
-- The boot filesystem is already mounted at "/" by k.vfs; this driver only
-- handles non-boot filesystems and hot-plug.

local M = {}

local ipc = require("k.ipc")
local vfs = require("k.vfs")
local log = require("k.log")

local mounted                                    -- {addr -> mountpoint}

local function mount_fs(addr)
  if mounted[addr] then return end
  if addr == _OCOS.boot_addr then return end     -- already at "/"
  local mp = "/mnt/" .. addr:sub(1, 8)
  -- /mnt may not exist on boot fs — that's fine, mount table is purely virtual
  local ok, err = vfs.mount(component.proxy(addr), mp)
  if ok then
    mounted[addr] = mp
    log.info("fs", "mounted " .. addr:sub(1, 8) .. " at " .. mp)
  else
    log.warn("fs", "mount " .. addr:sub(1, 8) .. " failed: " .. tostring(err))
  end
end

local function umount_fs(addr)
  local mp = mounted[addr]
  if not mp then return end
  vfs.umount(mp)
  mounted[addr] = nil
  log.info("fs", "umounted " .. addr:sub(1, 8))
end

function M.init()
  mounted = {}
  ipc.subscribe("oc.signal.component_added", function(p)
    local addr, ctype = p[1], p[2]
    if ctype == "filesystem" then mount_fs(addr) end
  end)
  ipc.subscribe("oc.signal.component_removed", function(p)
    local addr, ctype = p[1], p[2]
    if ctype == "filesystem" then umount_fs(addr) end
  end)
  for addr in component.list("filesystem") do mount_fs(addr) end
end

return M
