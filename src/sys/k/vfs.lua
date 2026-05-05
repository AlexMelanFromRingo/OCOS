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

local function resolve_raw(path)
  -- Mount-table walk. Does not follow symlinks. Used as the building block
  -- both for direct resolution and for the link follower below.
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

-- ---- Symbolic links -----------------------------------------------------
--
-- The OC managed filesystem has no native symlink primitive, so we encode
-- a link as a file named `<name>.lnk` whose body is the target path
-- (one line, leading/trailing whitespace trimmed). vfs.list, vfs.exists,
-- vfs.open and friends transparently follow them; vfs.readlink and
-- vfs.symlink expose the raw form for shell tools (ln -s, ls -l).

local LINK_EXT     = ".lnk"
local MAX_LINK_DEPTH = 8

local function read_link_target(proxy, sub_with_ext)
  local h = invoke(proxy.address, "open", sub_with_ext, "r")
  if not h then return nil end
  local body = ""
  while true do
    local chunk = invoke(proxy.address, "read", h, math.maxinteger)
    if not chunk or chunk == "" then break end
    body = body .. chunk
  end
  invoke(proxy.address, "close", h)
  return (body:gsub("[\r\n%s]+$", ""))
end

local function exists_raw(path)
  local proxy, sub = resolve_raw(path)
  if not proxy then return false end
  return invoke(proxy.address, "exists", sub) and true or false
end

local function follow_links(path, depth)
  depth = depth or 0
  if depth > MAX_LINK_DEPTH then return nil, "too many levels of symbolic links" end

  local parts = {}
  for p in path:gmatch("[^/]+") do parts[#parts + 1] = p end
  if #parts == 0 then return path end

  local cur = ""
  for i, p in ipairs(parts) do
    cur = cur .. "/" .. p
    local link_path = cur .. LINK_EXT
    local proxy, sub = resolve_raw(link_path)
    if proxy then
      local ok, exists = pcall(invoke, proxy.address, "exists", sub)
      if ok and exists then
        local target = read_link_target(proxy, sub)
        if target and target ~= "" then
          if target:sub(1, 1) ~= "/" then
            local parent = cur:match("(.*)/") or "/"
            if parent == "" then parent = "/" end
            target = parent .. "/" .. target
          end
          local rest = ""
          if i < #parts then rest = "/" .. table.concat(parts, "/", i + 1) end
          local new_path = M.canonical(target .. rest)
          return follow_links(new_path, depth + 1)
        end
      end
    end
  end
  return path
end

local function resolve(path)
  path = M.canonical(path)
  local resolved, err = follow_links(path)
  if not resolved then return nil, err end
  return resolve_raw(resolved)
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
  local entries = invoke(proxy.address, "list", sub)
  if not entries then return entries end
  -- Hide the .lnk encoding: a file `foo.lnk` is presented to callers as
  -- `foo` (its symlink name). If both `foo` and `foo.lnk` exist (which
  -- shouldn't, but callers may create it) the real `foo` wins.
  local seen, out = {}, {}
  for _, name in ipairs(entries) do
    local clean = (name:gsub("/$", ""))
    if clean:sub(-#LINK_EXT) == LINK_EXT then
      local stripped = clean:sub(1, -#LINK_EXT - 1)
      if not seen[stripped] then
        seen[stripped] = true
        out[#out + 1] = stripped
      end
    else
      seen[clean] = true
      out[#out + 1] = name
    end
  end
  return out
end

function M.exists(path)
  path = M.canonical(path)
  local resolved = follow_links(path) or path
  if exists_raw(resolved) then return true end
  -- A dangling symlink should still be treated as "exists" from the user's
  -- perspective; otherwise rm/ls would refuse to touch it.
  return exists_raw(path .. LINK_EXT)
end

function M.is_symlink(path)
  path = M.canonical(path)
  return exists_raw(path .. LINK_EXT)
end

function M.readlink(path)
  path = M.canonical(path)
  local proxy, sub = resolve_raw(path .. LINK_EXT)
  if not proxy then return nil, "not a symlink" end
  if not invoke(proxy.address, "exists", sub) then return nil, "not a symlink" end
  return read_link_target(proxy, sub)
end

function M.symlink(target, link_path)
  link_path = M.canonical(link_path)
  if exists_raw(link_path) then return nil, "destination exists: " .. link_path end
  local proxy, sub = resolve_raw(link_path .. LINK_EXT)
  if not proxy then return nil, sub end
  local h, err = invoke(proxy.address, "open", sub, "w")
  if not h then return nil, err end
  invoke(proxy.address, "write", h, target .. "\n")
  invoke(proxy.address, "close", h)
  return true
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
  -- For symlinks, remove the link file itself; never traverse into the
  -- target. For everything else, follow once and remove the resolved
  -- node.
  path = M.canonical(path)
  if M.is_symlink(path) then
    local proxy, sub = resolve_raw(path .. LINK_EXT)
    if not proxy then return nil, sub end
    return invoke(proxy.address, "remove", sub)
  end
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
