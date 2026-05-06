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
  -- The picker has to avoid tmpfs — it's RAM-backed and doesn't
  -- survive a Minecraft restart, which would silently lose every
  -- account the user created. Order of preference:
  --   1. existing /etc/passwd anywhere persistent
  --   2. boot fs if it's writable (production install)
  --   3. any non-tmpfs /mnt/<addr> (OCVM dev with two real disks)
  --   4. tmpfs as a last resort with a warning written to k.log
  local tmp_addr = computer.tmpAddress and computer.tmpAddress()

  if vfs.exists(PASSWD_PATH) then return PASSWD_PATH end
  for _, m in ipairs(vfs.mounts()) do
    if m.prefix:sub(1, 5) == "/mnt/" and m.address ~= tmp_addr then
      local p = m.prefix .. "/etc/passwd"
      if vfs.exists(p) then return p end
    end
  end

  local boot = _OCOS and _OCOS.boot_addr and component.proxy(_OCOS.boot_addr)
  if boot and boot.isReadOnly and not boot.isReadOnly() then
    pcall(vfs.mkdir, "/etc")
    return PASSWD_PATH
  end

  for _, m in ipairs(vfs.mounts()) do
    if m.prefix:sub(1, 5) == "/mnt/" and m.address ~= tmp_addr then
      pcall(vfs.mkdir, m.prefix .. "/etc")
      return m.prefix .. "/etc/passwd"
    end
  end

  -- Tmpfs only as a last resort. Note it loudly so a future post-mortem
  -- has a paper trail.
  for _, m in ipairs(vfs.mounts()) do
    if m.prefix:sub(1, 5) == "/mnt/" then
      pcall(require("k.log").warn, "users",
        "/etc/passwd is on tmpfs — accounts will be lost on MC restart")
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

-- M.default_caps(name, role, home)
--   role = "admin"  → caps = {"*"}     (full privileges; sudo works)
--   role = "user"   → caps = limited set: exec, write to home + tmp, all
--                     hardware components, IPC. Cannot touch /etc, /sys
--                     or any other user's home.
-- For root (uid = 0) we always return {"*"} regardless of role argument.
function M.default_caps(name, role, home)
  if name == "root" or role == "admin" then return { "*" } end
  return {
    "syscall:exec",
    "syscall:write:" .. (home or "/home/" .. name) .. "/*",
    "syscall:write:/tmp/*",
    "component:gpu",
    "component:screen",
    "component:keyboard",
    "component:internet",
    "component:modem",
    "component:tunnel",
    "component:data",
    "component:filesystem:*",
    "ipc:channel:*",
  }
end

local function next_uid(db, requested, name)
  if requested then return requested end
  if name == "root" then return 0 end
  local max = 999
  for _, rec in pairs(db) do
    if (rec.uid or 0) > max then max = rec.uid end
  end
  return max + 1
end

function M.create(name, password, opts)
  opts = opts or {}
  local db, path = load_db()
  if db[name] then return nil, "user already exists" end
  local salt = rand_hex(16)
  local iters = opts.iters or DEFAULT_ITERS
  local hex = pbkdf2.derive(password, salt, iters)
  local home = opts.home or ("/home/" .. name)
  db[name] = {
    uid    = next_uid(db, opts.uid, name),
    gid    = opts.gid or 1000,
    salt   = salt,
    pbkdf2 = hex,
    iters  = iters,
    home   = home,
    shell  = opts.shell or "/bin/sh.lua",
    caps   = opts.caps or M.default_caps(name, opts.role or "user", home),
  }
  -- Best-effort homedir creation. We don't error if it fails (the user
  -- may be on a read-only boot fs in dev; production installs put OCOS
  -- on a writable disk and this just works).
  pcall(vfs.mkdir, home)
  local ok, err = save_db(db, path)
  if ok then
    pcall(require("lib.auth.audit").write,
      { kind = "user.create", user = name, target = path,
        detail = "role=" .. (opts.role or "user") .. " uid=" .. tostring(db[name].uid) })
  end
  return ok, err
end

function M.is_admin(name)
  local rec = M.get(name); if not rec then return false end
  for _, c in ipairs(rec.caps or {}) do
    if c == "*" then return true end
  end
  return false
end

function M.verify(name, password)
  local rec = M.get(name); if not rec then return false end
  return pbkdf2.verify(password, rec.salt, rec.iters, rec.pbkdf2)
end

-- Replace the cap-set on an existing account in-place. Used by the
-- usermod CLI to promote / demote users without recreating them. The
-- caller is expected to be admin (cap.enforce=true denies the write
-- anyway since the path lives under /etc).
function M.set_caps(name, caps)
  local db, path = load_db()
  if not db[name] then return nil, "no such user" end
  db[name].caps = caps
  local ok, err = save_db(db, path)
  if ok then
    pcall(require("lib.auth.audit").write,
      { kind = "user.caps", user = name, target = path,
        detail = "caps=" .. table.concat(caps, ",") })
  end
  return ok, err
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
  local ok, err = save_db(db, path)
  if ok then
    pcall(require("lib.auth.audit").write,
      { kind = "user.passwd", user = name, target = path })
  end
  return ok, err
end

function M.remove(name)
  local db, path = load_db()
  if not db[name] then return nil, "no such user" end
  db[name] = nil
  local ok, err = save_db(db, path)
  if ok then
    pcall(require("lib.auth.audit").write,
      { kind = "user.remove", user = name, target = path })
  end
  return ok, err
end

function M.empty()
  -- load_db returns (table, path); the parens collapse the multi-return so
  -- next() does not get `path` as a second argument and complain about it
  -- as an "invalid key".
  return next((load_db())) == nil
end

function M.has_admin()
  -- True if at least one user holds the wildcard cap. Used by sessiond
  -- to decide whether to fall through to the rescue (root) path: if a
  -- fresh install only has limited-cap accounts, /etc/passwd would
  -- otherwise lock the operator out of admin tasks entirely.
  for _, rec in pairs((load_db())) do
    for _, c in ipairs(rec.caps or {}) do
      if c == "*" then return true end
    end
  end
  return false
end

return M
