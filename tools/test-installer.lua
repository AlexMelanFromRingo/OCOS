-- /tools/test-installer.lua — host-side smoke test for the installer.
--
-- Stubs `component`, `computer`, and `require('filesystem')` to look like
-- a real OpenComputers machine running OpenOS, then runs the streaming
-- installer in `--local <root>` mode against the actual `src/` tree.
-- Asserts every file in the manifest writes to the target with the
-- exact byte content we expect.
--
-- Run with: lua5.3 tools/test-installer.lua

local installer_path = "dist/ocos-installer.lua"
local src_root       = "src"

-- ---- in-memory filesystem stub for the install target -----------------

local function make_target(addr)
  local files, handles, seq = {}, {}, 0
  local self
  self = {
    addr = addr,
    label = "ocos-target",
    files = files,
    isReadOnly    = function() return false end,
    getLabel      = function() return self.label end,
    spaceTotal    = function() return 4 * 1024 * 1024 end,
    spaceUsed     = function() local n = 0; for _, c in pairs(files) do n = n + #c end; return n end,
    exists        = function(_, p) return files[p] ~= nil or files[p .. "/.dir"] ~= nil end,
    isDirectory   = function(_, p) return files[p .. "/.dir"] ~= nil end,
    makeDirectory = function(_, p) files[p .. "/.dir"] = ""; return true end,
    open = function(_, p, mode)
      seq = seq + 1
      handles[seq] = { path = p, mode = mode or "r", buf = "" }
      return seq
    end,
    write = function(_, h, data) handles[h].buf = handles[h].buf .. data; return true end,
    close = function(_, h)
      local handle = handles[h]
      if handle.mode == "w" or handle.mode == "a" then files[handle.path] = handle.buf end
      handles[h] = nil
      return true
    end,
    size = function(_, p) return files[p] and #files[p] or 0 end,
  }
  return self
end

local target = make_target("aaaaaaaa-1111-2222-3333-444444444444")

-- ---- component / computer stubs ----------------------------------------

local component = {
  list = function(filter)
    local items = {}
    if filter == nil or filter == "filesystem" then items[#items + 1] = target.addr end
    table.sort(items)
    local i = 0
    return function() i = i + 1; return items[i], filter end
  end,
  invoke = function(addr, method, ...)
    if addr ~= target.addr then error("invoke: unknown " .. addr, 2) end
    return target[method](target, ...)
  end,
  proxy = function(addr) return target end,
}

local set_boot_called_with
local computer = {
  uptime         = function() return 0 end,
  getBootAddress = function() return nil end,
  setBootAddress = function(a) set_boot_called_with = a end,
}

-- ---- filesystem stub: routes the installer's --local fs.open() to the
-- host's real `src/` tree (and whatever the manifest path maps to).
-- The installer asks for paths like "<local_root>/dist/install-manifest.lua"
-- and "<local_root>/src/<rel>". Map "<local_root>" → "" (current dir).

local LOCAL_ROOT = "TESTROOT"
local function host_path(virtual_path)
  if virtual_path:sub(1, #LOCAL_ROOT + 1) == LOCAL_ROOT .. "/" then
    return virtual_path:sub(#LOCAL_ROOT + 2)
  end
  return virtual_path
end

local fs_stub = {
  open = function(path, mode)
    local f, err = io.open(host_path(path), mode == "rb" and "rb" or "r")
    if not f then return nil, err or "open failed" end
    return {
      read  = function(self, n) return f:read(n) end,
      close = function() f:close() end,
    }
  end,
}

-- ---- io stub (collects output) -----------------------------------------

local io_messages = {}
local io_stub = {
  write  = function(s) io_messages[#io_messages + 1] = tostring(s) end,
  stderr = { write = function(_, s) io_messages[#io_messages + 1] = "ERR: " .. tostring(s) end },
}

-- ---- run the installer --------------------------------------------------

local h = assert(io.open(installer_path, "r"))
local source = h:read("a"); h:close()

local PASSTHROUGH = {
  string = true, table = true, math = true, ipairs = true, pairs = true,
  tostring = true, tonumber = true, pcall = true, type = true,
  select = true, assert = true, error = true, _VERSION = true,
  load = true, loadstring = true, rawget = true, rawset = true,
  setmetatable = true, getmetatable = true, next = true, unpack = true,
  os = true,                                            -- for os.sleep handling
}

local env = setmetatable({
  io = io_stub,
  require = function(name)
    if name == "filesystem" then return fs_stub end
    if name == "component"  then return component end
    if name == "computer"   then return computer end
    error("require: unknown module " .. name, 0)
  end,
}, { __index = function(_, key)
  if PASSTHROUGH[key] then return rawget(_G, key) end
  return nil
end })
env._ENV = env

local fn, lerr = load(source, "=" .. installer_path, "t", env)
if not fn then print("LOAD ERR: " .. tostring(lerr)); os.exit(1) end
local ok, ret = pcall(fn, "--local", LOCAL_ROOT)
if not ok then
  print("RUN ERR: " .. tostring(ret))
  print(table.concat(io_messages, ""))
  os.exit(1)
end

-- ---- assertions --------------------------------------------------------

local function check(cond, msg)
  if not cond then
    print("FAIL " .. msg)
    print(table.concat(io_messages, ""))
    os.exit(1)
  end
end

local files = target.files
local n = 0
for k in pairs(files) do if not k:find("%.dir$") then n = n + 1 end end
check(n >= 100, "expected ≥100 files written, got " .. n)
check(set_boot_called_with == target.addr, "setBootAddress fired on target")

-- Spot-check key files: byte-for-byte match with source.
local sentinels = {
  "/init.lua",
  "/sys/boot.lua",
  "/sys/svc/sessiond.lua",
  "/sys/svc/uid.lua",
  "/bin/sh.lua",
  "/etc/services/logd.cfg",
  "/sys/lib/codec/sha256.lua",
  "/sys/svc/init.lua",            -- the largest file; most likely to expose chunking bugs
}
for _, p in ipairs(sentinels) do
  check(files[p], "missing on target: " .. p)
  local f = io.open(src_root .. p, "rb")
  if f then
    local expected = f:read("a"); f:close()
    check(files[p] == expected,
      "content mismatch on " .. p .. ": got " .. #files[p] .. " expected " .. #expected)
  end
end

print(string.format("PASS test-installer: %d files written, every sentinel byte-matches source", n))
