-- /tools/test-installer.lua — host-side smoke test for the installer.
--
-- The installer expects an OpenComputers `component`/`computer` API. We
-- substitute a tiny stub that records every operation, run the installer
-- chunk against an in-memory virtual disk, and assert that:
--   * exactly one writable filesystem is selected as the target
--   * every W() call lands as expected (file count + path shape)
--   * setBootAddress is called on the selected disk
--   * no Lua error escapes
--
-- Run with:
--   lua5.3 tools/test-installer.lua
--
-- Returns exit 0 on pass, non-zero on any failure.

local installer_path = arg and arg[1] or "dist/ocos-installer.lua"

-- ---- in-memory filesystem stub -----------------------------------------

local function make_fs(addr, readonly)
  local files = {}                                -- {[path] = string}
  local handles = {}
  local seq = 0
  return {
    addr      = addr,
    readonly  = readonly,
    files     = files,
    label     = "stub-" .. addr:sub(1, 4),
    isReadOnly = function() return readonly end,
    getLabel   = function(self) return self.label end,
    setLabel   = function(self, l) self.label = l; return l end,
    spaceTotal = function() return 1024 * 1024 end,
    spaceUsed  = function()
      local n = 0; for _, c in pairs(files) do n = n + #c end; return n
    end,
    exists     = function(_, p) return files[p] ~= nil or files[p .. "/.dir"] ~= nil end,
    isDirectory = function(_, p) return files[p .. "/.dir"] ~= nil end,
    makeDirectory = function(_, p) files[p .. "/.dir"] = ""; return true end,
    open       = function(_, p, mode)
      mode = mode or "r"
      if readonly and (mode == "w" or mode == "a") then return nil, "read-only" end
      seq = seq + 1
      handles[seq] = { path = p, mode = mode, pos = 1, buf = "" }
      if mode == "r" then handles[seq].buf = files[p] or "" end
      return seq
    end,
    write = function(_, h, data)
      handles[h].buf = handles[h].buf .. data
      return true
    end,
    read = function(_, h, n)
      local handle = handles[h]
      if handle.pos > #handle.buf then return nil end
      local out = handle.buf:sub(handle.pos, handle.pos + n - 1)
      handle.pos = handle.pos + #out
      return out
    end,
    close = function(_, h)
      local handle = handles[h]
      if handle.mode == "w" or handle.mode == "a" then
        files[handle.path] = (handle.mode == "a" and (files[handle.path] or "") or "") .. handle.buf
      end
      handles[h] = nil
      return true
    end,
  }
end

-- ---- component / computer stubs ----------------------------------------

local boot_fs = make_fs("aaaaaaaa-1111-2222-3333-444444444444", true)
local target  = make_fs("bbbbbbbb-1111-2222-3333-444444444444", false)
local fses    = { [boot_fs.addr] = boot_fs, [target.addr] = target }
local boot_addr = boot_fs.addr

local component = {
  list = function(filter)
    local items = {}
    if filter == nil or filter == "filesystem" then
      for addr in pairs(fses) do items[#items + 1] = addr end
    end
    if filter == "eeprom" then items[#items + 1] = "ee-stub-1" end
    table.sort(items)
    local i = 0
    return function() i = i + 1; return items[i], filter end
  end,
  invoke = function(addr, method, ...)
    local proxy = fses[addr]
    if not proxy then error("invoke: no such address " .. addr, 2) end
    local fn = proxy[method]
    if not fn then error("invoke: no such method " .. method, 2) end
    return fn(proxy, ...)
  end,
  proxy = function(addr) return fses[addr] end,
}

local set_boot_called_with = nil
local computer = {
  uptime = function() return 0 end,
  getBootAddress = function() return boot_addr end,
  setBootAddress = function(a) set_boot_called_with = a end,
  shutdown = function() end,
  realTime = function() return 0 end,
}

-- io stubs that just collect output so the test stays quiet under -q.
local io_messages = {}
local io = {
  write  = function(s) io_messages[#io_messages + 1] = s end,
  stderr = { write = function(_, s) io_messages[#io_messages + 1] = "ERR: " .. s end },
}

-- ---- run the installer --------------------------------------------------

local f = assert(io and io.open or _G.io.open)
local src_h = assert(_G.io.open(installer_path, "r"))
local source = src_h:read("a"); src_h:close()

-- Match the OpenOS sandbox shape exactly: `component` and `computer`
-- are NOT plain globals; the chunk has to require() them. If the
-- installer ever stops doing that this test will fail with the same
-- "attempt to index a nil value" the user saw on the real machine.
local PASSTHROUGH = {
  string = true, table = true, math = true, ipairs = true, pairs = true,
  tostring = true, tonumber = true, pcall = true, type = true,
  select = true, assert = true, error = true, _VERSION = true,
}

local env = setmetatable({
  io = io,
  require = function(name)
    if name == "component" then return component end
    if name == "computer"  then return computer  end
    error("require: unknown module in test: " .. tostring(name), 0)
  end,
}, { __index = function(_, key)
  if PASSTHROUGH[key] then return rawget(_G, key) end
  return nil
end })
env._ENV = env

local fn, lerr = load(source, "=" .. installer_path, "t", env)
if not fn then print("LOAD ERR: " .. tostring(lerr)); os.exit(1) end
local ok, ret = pcall(fn)
if not ok then print("RUN ERR: " .. tostring(ret)); print(table.concat(io_messages, "")); os.exit(1) end

-- ---- assertions --------------------------------------------------------

local function check(cond, msg)
  if not cond then print("FAIL " .. msg); print(table.concat(io_messages, "")); os.exit(1) end
end

local n = 0
for path in pairs(target.files) do
  if not path:find("%.dir$") then n = n + 1 end
end
check(n >= 100, "expected 100+ files written, got " .. n)
check(target.files["/init.lua"] and #target.files["/init.lua"] > 0, "/init.lua present and non-empty")
check(target.files["/sys/boot.lua"], "/sys/boot.lua present")
check(target.files["/bin/sh.lua"], "/bin/sh.lua present")
check(target.files["/etc/services/logd.cfg"], "logd unit present")
check(set_boot_called_with == target.addr, "setBootAddress was called on the target")
check(next(boot_fs.files) == nil, "boot fs left untouched")

print(string.format("PASS test-installer: %d files written, boot address set to %s",
  n, target.addr:sub(1, 8)))
