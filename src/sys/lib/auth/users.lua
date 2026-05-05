-- /sys/lib/auth/users.lua — user database stored at /etc/passwd.
--
-- /etc/passwd is a Lua table:
--   return {
--     ["root"] = { uid = 0, gid = 0, salt = "<hex>", pbkdf2 = "<hex>", iters = 5000,
--                  home = "/home/root", shell = "/bin/sh.lua", caps = {"*"} },
--     ["alex"] = { uid = 1000, gid = 1000, ... },
--   }

local M = {}

local vfs    = require("k.vfs")
local pbkdf2 = require("lib.codec.pbkdf2")
local sha    = require("lib.codec.sha256")

local PASSWD_PATH  = "/etc/passwd"
local DEFAULT_ITERS = 5000                        -- ~250 ms on T3 Lua 5.3

local function find_passwd_path()
  -- Prefer the writable /mnt/X/etc/passwd if /etc is read-only; fall back to
  -- the source-tree path so a fresh boot still has root.
  if vfs.exists(PASSWD_PATH) then return PASSWD_PATH end
  for _, m in ipairs(vfs.mounts()) do
    if m.prefix:sub(1, 5) == "/mnt/" then
      pcall(vfs.mkdir, m.prefix .. "/etc")
      local p = m.prefix .. "/etc/passwd"
      if vfs.exists(p) then return p end
    end
  end
  -- Default to the first writable mount so create() can write the initial table.
  for _, m in ipairs(vfs.mounts()) do
    if m.prefix:sub(1, 5) == "/mnt/" then
      pcall(vfs.mkdir, m.prefix .. "/etc")
      return m.prefix .. "/etc/passwd"
    end
  end
end

local function rand_hex(n)
  local data
  local addr = component.list("data")()
  if addr then
    local ok, r = pcall(component.invoke, addr, "random", n)
    if ok and r then data = r end
  end
  if not data then
    -- Fall back to mixing uptime, addresses and the kernel ring contents
    -- through SHA-256 — reasonably unpredictable on a physical machine.
    local rt = (computer.realTime and computer.realTime()) or 0
    local seed = tostring(computer.uptime()) .. tostring(rt) .. tostring(_OCOS.boot_addr)
    for a in component.list() do seed = seed .. a end
    data = sha.bytes(seed):sub(1, n)
  end
  return (data:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local cache

local function load_db()
  local path = find_passwd_path()
  if not path or not vfs.exists(path) then return {}, path end
  local src = vfs.read_all(path)
  local fn, err = load(src, "=" .. path, "t", {})
  if not fn then error("passwd: " .. tostring(err), 0) end
  local ok, t = pcall(fn)
  if not ok or type(t) ~= "table" then return {}, path end
  return t, path
end

local function save_db(db, path)
  local ordered = {}
  for k in pairs(db) do ordered[#ordered + 1] = k end
  table.sort(ordered)
  local out = { "return {" }
  for _, name in ipairs(ordered) do
    local r = db[name]
    out[#out + 1] = string.format(
      "  [%q] = { uid=%d, gid=%d, salt=%q, pbkdf2=%q, iters=%d, home=%q, shell=%q, caps={%s} },",
      name, r.uid, r.gid, r.salt, r.pbkdf2, r.iters, r.home, r.shell,
      table.concat((function()
        local q = {}
        for _, c in ipairs(r.caps or {}) do q[#q + 1] = string.format("%q", c) end
        return q
      end)(), ", "))
  end
  out[#out + 1] = "}"
  return vfs.write_all(path, table.concat(out, "\n") .. "\n")
end

function M.list()
  local db = load_db()
  cache = db
  local names = {}
  for k in pairs(db) do names[#names + 1] = k end
  table.sort(names)
  return names
end

function M.get(name)
  local db = load_db(); cache = db
  return db[name]
end

function M.create(name, password, opts)
  opts = opts or {}
  local db, path = load_db()
  if db[name] then return nil, "user already exists" end
  local salt = rand_hex(16)
  local iters = opts.iters or DEFAULT_ITERS
  local hex = pbkdf2.derive(password, salt, iters)
  db[name] = {
    uid    = opts.uid or (next(db) and 1000 + #db or 0),
    gid    = opts.gid or 1000,
    salt   = salt,
    pbkdf2 = hex,
    iters  = iters,
    home   = opts.home or ("/home/" .. name),
    shell  = opts.shell or "/bin/sh.lua",
    caps   = opts.caps or { "*" },
  }
  return save_db(db, path)
end

function M.verify(name, password)
  local rec = M.get(name); if not rec then return false end
  return pbkdf2.verify(password, rec.salt, rec.iters, rec.pbkdf2)
end

function M.set_password(name, password, opts)
  opts = opts or {}
  local db, path = load_db()
  if not db[name] then return nil, "no such user" end
  local salt = rand_hex(16)
  local iters = opts.iters or db[name].iters or DEFAULT_ITERS
  db[name].salt   = salt
  db[name].pbkdf2 = pbkdf2.derive(password, salt, iters)
  db[name].iters  = iters
  return save_db(db, path)
end

function M.remove(name)
  local db, path = load_db()
  if not db[name] then return nil, "no such user" end
  db[name] = nil
  return save_db(db, path)
end

function M.empty()
  -- load_db returns (table, path); the parens collapse the multi-return so
  -- next() does not get `path` as a second argument and complain about it
  -- as an "invalid key".
  return next((load_db())) == nil
end

return M
