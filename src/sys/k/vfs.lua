-- /sys/k/vfs.lua — virtual filesystem with longest-prefix mount table.
--
-- M1 scope:
--   vfs.init({boot_addr=...}) mounts boot at "/" and tmpfs at "/tmp".
--   vfs.open(path, mode) -> handle    handle:read(n) / handle:write(s)
--                                     handle:seek(whence,off) / handle:close()
--   vfs.list(path), vfs.exists, vfs.isdir, vfs.size, vfs.lastmod
--   vfs.mkdir, vfs.remove, vfs.rename
--   vfs.canonical(path) -> string
--
-- A mount entry is { prefix, proxy }. We keep the array sorted by prefix
-- length descending so the first match wins.

local M = {}

local mounts                                     -- array of {prefix, proxy}
local invoke = component.invoke

local function split(path)
  local parts = {}
  for seg in path:gmatch("[^/]+") do
    if seg == ".." then
      parts[#parts] = nil
    elseif seg ~= "." and seg ~= "" then
      parts[#parts + 1] = seg
    end
  end
  return parts
end

function M.canonical(path)
  if path:sub(1, 1) ~= "/" then path = "/" .. path end
  local parts = split(path)
  if #parts == 0 then return "/" end
  return "/" .. table.concat(parts, "/")
end

local function resolve(path)
  path = M.canonical(path)
  for i = 1, #mounts do
    local m = mounts[i]
    local matched
    if m.prefix == "/" then
      matched = true                              -- root mount catches all
    elseif path == m.prefix then
      matched = true
    elseif path:sub(1, #m.prefix + 1) == m.prefix .. "/" then
      matched = true
    end
    if matched then
      local sub
      if m.prefix == "/" then
        sub = path
      else
        sub = path:sub(#m.prefix + 1)
        if sub == "" then sub = "/" end
      end
      return m.proxy, sub
    end
  end
  return nil, "no mount for " .. path
end

local function sort_mounts()
  table.sort(mounts, function(a, b) return #a.prefix > #b.prefix end)
end

function M.mount(proxy, prefix)
  prefix = M.canonical(prefix)
  for _, m in ipairs(mounts) do
    if m.prefix == prefix then return nil, "already mounted: " .. prefix end
  end
  mounts[#mounts + 1] = { prefix = prefix, proxy = proxy }
  sort_mounts()
  return true
end

function M.umount(prefix)
  prefix = M.canonical(prefix)
  for i, m in ipairs(mounts) do
    if m.prefix == prefix then table.remove(mounts, i); return true end
  end
  return nil, "not mounted"
end

function M.mounts()
  local out = {}
  for _, m in ipairs(mounts) do out[#out + 1] = { prefix = m.prefix, address = m.proxy.address } end
  return out
end

-- ---- File handles -------------------------------------------------------

local Handle = {}
Handle.__index = Handle

function Handle:read(n)
  return invoke(self._addr, "read", self._h, n or math.maxinteger)
end

function Handle:write(s)
  return invoke(self._addr, "write", self._h, s)
end

function Handle:seek(whence, offset)
  return invoke(self._addr, "seek", self._h, whence or "cur", offset or 0)
end

function Handle:close()
  if self._h then
    invoke(self._addr, "close", self._h)
    self._h = nil
  end
end

local function check_write_cap(path, mode)
  if mode == "r" then return true end
  local cap = require("k.cap")
  if not cap.is_enforcing() then return true end
  local sched_mod = require("k.sched")
  local current = sched_mod.current()
  local proc_caps = current and current.caps
  -- Kernel-level callers (no current process) are trusted.
  if not current then return true end
  local action = "syscall:write:" .. path
  return cap.check(proc_caps, action, { proc = current, target = path }), action
end

function M.open(path, mode)
  mode = mode or "r"
  path = M.canonical(path)
  local ok, action = check_write_cap(path, mode)
  if not ok then return nil, "permission denied: " .. action end
  local proxy, sub = resolve(path)
  if not proxy then return nil, sub end
  local h, err = invoke(proxy.address, "open", sub, mode)
  if not h then return nil, err end
  return setmetatable({ _addr = proxy.address, _h = h, mode = mode, path = path }, Handle)
end

function M.list(path)
  local proxy, sub = resolve(path); if not proxy then return nil, sub end
  return invoke(proxy.address, "list", sub)
end

function M.exists(path)
  local proxy, sub = resolve(path); if not proxy then return false end
  return invoke(proxy.address, "exists", sub) and true or false
end

function M.isdir(path)
  local proxy, sub = resolve(path); if not proxy then return false end
  return invoke(proxy.address, "isDirectory", sub) and true or false
end

function M.size(path)
  local proxy, sub = resolve(path); if not proxy then return nil, sub end
  return invoke(proxy.address, "size", sub)
end

function M.lastmod(path)
  local proxy, sub = resolve(path); if not proxy then return nil, sub end
  return invoke(proxy.address, "lastModified", sub)
end

function M.mkdir(path)
  local proxy, sub = resolve(path); if not proxy then return nil, sub end
  return invoke(proxy.address, "makeDirectory", sub)
end

function M.remove(path)
  local proxy, sub = resolve(path); if not proxy then return nil, sub end
  return invoke(proxy.address, "remove", sub)
end

function M.rename(old, new)
  local pa, sa = resolve(old); if not pa then return nil, sa end
  local pb, sb = resolve(new); if not pb then return nil, sb end
  if pa.address ~= pb.address then
    return nil, "cross-device rename not supported in M1"
  end
  return invoke(pa.address, "rename", sa, sb)
end

function M.read_all(path)
  local h, err = M.open(path, "r")
  if not h then return nil, err end
  local parts, chunk = {}, nil
  repeat chunk = h:read(math.maxinteger or math.huge); if chunk then parts[#parts + 1] = chunk end until not chunk
  h:close()
  return table.concat(parts)
end

function M.write_all(path, data)
  local h, err = M.open(path, "w")
  if not h then return nil, err end
  h:write(data)
  h:close()
  return true
end

-- ---- init ---------------------------------------------------------------

function M.init(opts)
  mounts = {}
  local boot_proxy = component.proxy(opts.boot_addr)
  M.mount(boot_proxy, "/")
  local tmp_addr = computer.tmpAddress()
  if tmp_addr then
    M.mount(component.proxy(tmp_addr), "/tmp")
  end
end

return M
