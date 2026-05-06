-- /sys/lib/diag/trace.lua — append-mode debug trace shared by init,
-- sessiond, uid and other services. Two writers:
--
--   trace_via_vfs — preferred path; goes through k.vfs (mount table,
--                   cap checks, symlink follow). Picks the first
--                   writable /mnt/<addr>/var/log, otherwise boot fs.
--
--   trace_via_raw — fallback when vfs.open fails (cap denial, fs
--                   not yet mounted, etc.). Talks straight to a
--                   filesystem proxy via component.invoke. The trace
--                   goes onto the first writable filesystem the
--                   driver enumerates.
--
-- The fallback is what guarantees we always see *something* in
-- post-mortem when uid panics before vfs is ready or while caps are
-- enforcing badly.

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
  pcall(vfs.mkdir, "/var")
  pcall(vfs.mkdir, "/var/log")
  return "/var/log"
end

local function pick_raw_fs()
  -- Find a writable filesystem component without going through vfs.
  -- Used as the post-vfs-failure fallback.
  for addr in component.list("filesystem") do
    local ok, ro = pcall(component.invoke, addr, "isReadOnly")
    if ok and not ro then return addr end
  end
end

local function raw_append(addr, path, line)
  if not addr then return end
  -- Make sure the parent dirs exist; OC's append mode needs them.
  pcall(component.invoke, addr, "makeDirectory", "/var")
  pcall(component.invoke, addr, "makeDirectory", "/var/log")
  local h = pcall(function() return component.invoke(addr, "open", path, "a") end)
  local ok, handle = pcall(component.invoke, addr, "open", path, "a")
  if not ok or not handle then return end
  pcall(component.invoke, addr, "write", handle, line)
  pcall(component.invoke, addr, "close", handle)
end

function M.for_name(name)
  local path, raw_addr
  return function(msg)
    local line = string.format("[%8.3f] %s\n", computer.uptime(), msg)
    if not path then path = pick_dir() .. "/" .. name .. ".trace" end
    local h = vfs.open(path, "a")
    if h then
      pcall(h.write, h, line)
      pcall(h.close, h)
      return
    end
    -- vfs failed — go raw.
    if not raw_addr then raw_addr = pick_raw_fs() end
    raw_append(raw_addr, "/var/log/" .. name .. ".trace", line)
  end
end

-- M.panic(name, msg) — emergency post-mortem dump. Always uses the raw
-- component path because by the time you call it the vfs / cap stack
-- might be the very thing that failed.
function M.panic(name, msg)
  local addr = pick_raw_fs()
  if not addr then return end
  raw_append(addr, "/" .. name .. ".panic",
    string.format("[%8.3f] %s\n", computer.uptime(), msg))
end

return M
