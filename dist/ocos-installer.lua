-- OCOS streaming installer.
-- Fetches dist/install-manifest.lua (the file index) from a base URL,
-- then downloads each file individually and writes it to a target disk.
--
-- Usage on OpenOS:
--   wget https://raw.githubusercontent.com/AlexMelanFromRingo/OCOS/main/dist/ocos-installer.lua /tmp/ocos.lua
--   /tmp/ocos.lua                            -- pick the only writable disk + use the default GitHub URL
--   /tmp/ocos.lua 88895671                   -- explicit target by address prefix
--   /tmp/ocos.lua 88895671 https://my.fork   -- target + custom base URL
--   /tmp/ocos.lua --local /mnt/loot          -- read files from a local mount instead of HTTP
--   /tmp/ocos.lua --no-flash-eeprom           -- skip flashing the EEPROM (default IS to flash)
--   /tmp/ocos.lua --no-setup-root              -- skip the first-boot root-password prompt

local args = { ... }

local component = component or require("component")
local computer  = computer  or require("computer")
local invoke = component.invoke

local DEFAULT_BASE = "https://raw.githubusercontent.com/AlexMelanFromRingo/OCOS/main"

local function eprint(s) io.stderr:write(s .. "\n") end
local function ok(s)     io.write("[ok] " .. s .. "\n") end

-- ---- arg parsing -------------------------------------------------------

local target_prefix, base_url, local_root, flash_eeprom, non_interactive, skip_setup_root
do
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--local" then
      local_root = args[i + 1]
      if not local_root then eprint("--local needs a path"); return 2 end
      i = i + 2
    elseif a == "--flash-eeprom" then
      flash_eeprom = true
      non_interactive = true
      i = i + 1
    elseif a == "--no-flash-eeprom" then
      flash_eeprom = false
      non_interactive = true
      i = i + 1
    elseif a == "--no-setup-root" then
      skip_setup_root = true
      i = i + 1
    elseif a == "-y" or a == "--yes" then
      non_interactive = true
      flash_eeprom = (flash_eeprom == nil) and true or flash_eeprom
      skip_setup_root = (skip_setup_root == nil) and true or skip_setup_root
      i = i + 1
    elseif a:match("^https?://") then
      base_url = a
      i = i + 1
    else
      target_prefix = target_prefix or a
      i = i + 1
    end
  end
  base_url = base_url or DEFAULT_BASE
end

local function prompt(question, default)
  io.write(question .. " [" .. (default and "Y/n" or "y/N") .. "] ")
  io.write = io.write                              -- ensure flushed in OpenOS
  local reply = io.read()
  if not reply then return default end
  reply = reply:lower():gsub("^%s+", ""):gsub("%s+$", "")
  if reply == "" then return default end
  if reply == "y" or reply == "yes" or reply == "д" or reply == "да" then return true end
  if reply == "n" or reply == "no"  or reply == "н" or reply == "нет" then return false end
  return default
end

-- ---- target selection --------------------------------------------------

local function list_writable()
  local out = {}
  for addr, _ in component.list("filesystem") do
    local rok, ro = pcall(invoke, addr, "isReadOnly")
    if rok and not ro then
      local label = (pcall(invoke, addr, "getLabel") and invoke(addr, "getLabel")) or ""
      out[#out + 1] = {
        addr = addr, label = label,
        free = invoke(addr, "spaceTotal") - invoke(addr, "spaceUsed"),
      }
    end
  end
  return out
end

local function pick_target()
  local boot = computer.getBootAddress and computer.getBootAddress()
  local cands = {}
  for _, fs in ipairs(list_writable()) do
    if fs.addr ~= boot then cands[#cands + 1] = fs end
  end
  if #cands == 0 then return nil, "no writable non-boot filesystem found" end
  if target_prefix then
    for _, fs in ipairs(cands) do
      if fs.addr:sub(1, #target_prefix) == target_prefix then return fs end
    end
    return nil, "no writable disk matches prefix '" .. target_prefix .. "'"
  end
  if #cands == 1 then return cands[1] end
  io.write("Multiple writable disks found; pass an address prefix to pick one:\n")
  for _, fs in ipairs(cands) do
    io.write(string.format("  %s  (%s, %d bytes free)\n",
      fs.addr:sub(1, 8), fs.label ~= "" and fs.label or "<unlabelled>", fs.free))
  end
  return nil, "ambiguous target"
end

-- ---- network / local fetch --------------------------------------------

local internet_card
local function fetch_http(url)
  if not internet_card then
    local addr = component.list("internet")()
    if not addr then error("install: no internet card; pass --local <path>") end
    internet_card = component.proxy(addr)
  end
  local h, err = internet_card.request(url)
  if not h then error("request " .. url .. ": " .. tostring(err)) end
  local started = computer.uptime()
  while not h.finishConnect() do
    if computer.uptime() - started > 30 then h.close(); error("connect timeout: " .. url) end
    if os.sleep then os.sleep(0.05) end
  end
  local parts = {}
  while true do
    local chunk, rerr = h.read(8192)
    if chunk == nil then
      if rerr then h.close(); error("read " .. url .. ": " .. rerr) end
      break
    end
    if chunk == "" then
      if os.sleep then os.sleep(0.05) end
    else
      parts[#parts + 1] = chunk
    end
  end
  h.close()
  return table.concat(parts)
end

local function fetch_local(rel)
  -- rel starts with "/". local_root is e.g. /mnt/<addr> or any mounted dir.
  local path = local_root .. rel
  local fs = require("filesystem")
  local h, err = fs.open(path, "rb") or fs.open(path, "r")
  if not h then error("open " .. path .. ": " .. tostring(err)) end
  local parts = {}
  while true do
    local data = h:read(4096); if not data or data == "" then break end
    parts[#parts + 1] = data
  end
  h:close()
  return table.concat(parts)
end

local function fetch(rel)
  if local_root then return fetch_local("/src" .. rel) end
  return fetch_http(base_url .. "/src" .. rel)
end

-- ---- write helpers -----------------------------------------------------

local function ensure_dir(addr, path)
  local parts, cur = {}, ""
  for p in path:gmatch("[^/]+") do parts[#parts + 1] = p end
  for i = 1, #parts - 1 do
    cur = cur .. "/" .. parts[i]
    local ok_e, exists = pcall(invoke, addr, "exists", cur)
    if ok_e and not exists then pcall(invoke, addr, "makeDirectory", cur) end
  end
end

local function write_file(addr, path, content)
  ensure_dir(addr, path)
  local h, err = invoke(addr, "open", path, "w")
  if not h then return nil, err end
  -- OpenComputers' filesystem.write accepts arbitrarily-large strings, but
  -- on real-world 1.7.10 we've seen long single-call writes corrupt the
  -- file contents of the *next* file. Splitting into ≤4 KiB chunks (and
  -- letting each chunk yield the call budget naturally) sidesteps that.
  local off, total = 1, #content
  while off <= total do
    local nxt = math.min(off + 4096 - 1, total)
    local ok_w, werr = pcall(invoke, addr, "write", h, content:sub(off, nxt))
    if not ok_w then invoke(addr, "close", h); return nil, "write: " .. tostring(werr) end
    off = nxt + 1
  end
  invoke(addr, "close", h)
  -- Verify the file by reading back its size.
  local on_disk = invoke(addr, "size", path)
  if on_disk ~= total then return nil, "size mismatch: wrote " .. total .. " got " .. on_disk end
  return true
end

-- ---- main --------------------------------------------------------------

local target, terr = pick_target()
if not target then eprint("install: " .. terr); return 1 end
local target_addr = target.addr
ok("installing OCOS to " .. target_addr:sub(1, 8) ..
   " (" .. (target.label ~= "" and target.label or "<unlabelled>") .. ")")
ok((local_root and "source: local " .. local_root) or ("source: " .. base_url))

-- Interactive prompts when no flag forced the choice. Scripts pass -y or
-- the explicit --[no-]flash-eeprom flag to bypass.
if not non_interactive then
  local has_eeprom = component.list("eeprom")() ~= nil
  if has_eeprom then
    io.write("\n")
    flash_eeprom = prompt("Flash the EEPROM with OCOS BIOS? (one-way without a backup)", true)
  end
end
if flash_eeprom == nil then flash_eeprom = true end

-- Fetch the manifest.
local mfst_src
if local_root then
  local fs = require("filesystem")
  local h = assert(fs.open(local_root .. "/dist/install-manifest.lua", "r"))
  local parts = {}; while true do local d = h:read(4096); if not d or d == "" then break end; parts[#parts + 1] = d end
  h:close(); mfst_src = table.concat(parts)
else
  mfst_src = fetch_http(base_url .. "/dist/install-manifest.lua")
end
local mfst_fn, lerr = load(mfst_src, "=manifest", "t", {})
if not mfst_fn then eprint("install: bad manifest: " .. tostring(lerr)); return 1 end
local mok, mfst = pcall(mfst_fn); if not mok then eprint("install: manifest eval: " .. tostring(mfst)); return 1 end
if type(mfst) ~= "table" or not mfst.files then eprint("install: manifest must have a `files` array"); return 1 end

-- Pre-flight space check.
local total_bytes = 0
for _, entry in ipairs(mfst.files) do total_bytes = total_bytes + (entry.size or 0) end
local need = math.floor(total_bytes * 1.3)
if target.free < need then
  eprint(string.format("install: need ~%d bytes, target has %d free", need, target.free))
  return 1
end

-- Write each file.
local n, total = 0, #mfst.files
local failed = 0
for _, entry in ipairs(mfst.files) do
  n = n + 1
  io.write(string.format("\r[%d/%d] %s%s", n, total, entry.path, string.rep(" ", 24)))
  local ok_f, content = pcall(fetch, entry.path)
  if not ok_f then
    io.write("\n")
    eprint("FAIL fetch " .. entry.path .. ": " .. tostring(content))
    failed = failed + 1
  else
    local ok_w, werr = write_file(target_addr, entry.path, content)
    if not ok_w then
      io.write("\n")
      eprint("FAIL write " .. entry.path .. ": " .. tostring(werr))
      failed = failed + 1
    end
  end
end
io.write("\n")

if failed > 0 then
  eprint(string.format("install: %d/%d files failed", failed, total))
  return 1
end

-- Strip stale dev-only files left by previous installer revisions. An
-- earlier build of the manifest accidentally shipped /etc/boot.selftest
-- which puts the kernel into self-test-then-shutdown mode at boot. The
-- cleanup array gives us an explicit removal pass for paths like that.
if mfst.cleanup then
  for _, p in ipairs(mfst.cleanup) do
    if invoke(target_addr, "exists", p) then
      pcall(invoke, target_addr, "remove", p)
      ok("removed stale " .. p)
    end
  end
end

if computer.setBootAddress then
  computer.setBootAddress(target_addr)
  ok("set boot address to " .. target_addr:sub(1, 8))
end

-- ---- first-boot setup: root password + cap.enforce flip --------------
--
-- After a fresh install /etc/passwd is empty, so OCOS sessiond drops
-- straight to a passwordless root and runs with enforce=false. The
-- in-OS `setup-root` command can fix this on first boot, but the
-- friendlier path is to do it right here while we're already prompting
-- the user. We load the freshly-written sha256 / hmac / pbkdf2 modules
-- off the target disk, hash the chosen password, and write /etc/passwd
-- + /etc/security.cfg before the reboot.
local function read_target_file(path)
  local h, oerr = invoke(target_addr, "open", path, "r")
  if not h then return nil, oerr end
  local parts = {}
  while true do
    local chunk, rerr = invoke(target_addr, "read", h, 4096)
    if chunk == nil then if rerr then invoke(target_addr, "close", h); return nil, rerr end; break end
    if chunk == "" then break end
    parts[#parts + 1] = chunk
  end
  invoke(target_addr, "close", h)
  return table.concat(parts)
end

local function write_target_file(path, content)
  return write_file(target_addr, path, content)
end

local function masked_read()
  -- OpenOS's term.read({pwchar="*"}) handles the masking nicely if
  -- available; otherwise fall back to plain io.read (visible).
  local term_ok, term = pcall(require, "term")
  if term_ok and term and term.read then
    local s = term.read(nil, false, nil, "*")
    if s then s = s:gsub("\n$", "") end
    return s
  end
  return io.read()
end

local function require_from_target()
  -- Build a tiny require that resolves modules off the target disk.
  -- Only used to pull in the lib.codec.* chain; nothing else is loaded.
  local cache = {}
  local function resolve(name)
    if cache[name] then return cache[name] end
    local rel = "/sys/" .. name:gsub("%.", "/") .. ".lua"
    local src, ferr = read_target_file(rel)
    if not src then error("require " .. name .. ": " .. tostring(ferr)) end
    -- The chunk env exposes `require` (recurse) plus the host globals
    -- the codec modules touch (string, math, bit ops, component for the
    -- data-card fast path in sha256).
    local env = setmetatable({}, { __index = _G })
    env.require = resolve
    local chunk, cerr = load(src, "=" .. rel, "t", env)
    if not chunk then error("load " .. name .. ": " .. tostring(cerr)) end
    local res = chunk()
    cache[name] = res
    return res
  end
  return resolve
end

local want_setup = (not skip_setup_root)
if not non_interactive and want_setup then
  io.write("\n")
  want_setup = prompt("Set up root password now? (otherwise run `setup-root` after boot)", true)
end

if want_setup and not skip_setup_root then
  local p1, p2
  while true do
    io.write("root password (>= 6 chars): "); p1 = masked_read()
    if not p1 then io.write("\n"); want_setup = false; break end
    io.write("\nretype:                       "); p2 = masked_read()
    io.write("\n")
    if not p2 then want_setup = false; break end
    if p1 ~= p2 then eprint("passwords don't match — try again"); p1 = nil
    elseif #p1 < 6 then eprint("too short — at least 6 characters"); p1 = nil
    else break end
  end

  if p1 and want_setup then
    local req_ok, req_err = pcall(require_from_target)
    if req_ok then
      local resolve = req_err
      local pbkdf2 = resolve("lib.codec.pbkdf2")
      local sha    = resolve("lib.codec.sha256")
      -- Generate a 16-byte salt. Prefer the data card's hardware RNG
      -- when present; otherwise fall back to a sha256 of uptime + a
      -- few component addresses, which is enough entropy for an
      -- install-time secret.
      local salt_hex
      do
        local data
        local data_addr = component.list("data")()
        if data_addr then
          local rok, raw = pcall(invoke, data_addr, "random", 16)
          if rok and raw then data = raw end
        end
        if not data then
          local seed = tostring(computer.uptime()) .. tostring(target_addr)
          for a in component.list() do seed = seed .. a end
          data = sha.bytes(seed):sub(1, 16)
        end
        salt_hex = (data:gsub(".", function(c) return string.format("%02x", c:byte()) end))
      end

      io.write("hashing... ")
      local hex = pbkdf2.derive(p1, salt_hex, 5000)
      io.write("done\n")

      -- Write /etc/passwd: just the root entry, formatted exactly the
      -- way users.lua's save_db emits it so the on-disk syntax stays
      -- canonical.
      local passwd = table.concat({
        "return {",
        string.format(
          "  [%q] = { uid=0, gid=0, salt=%q, pbkdf2=%q, iters=5000, home=%q, shell=%q, caps={%q} },",
          "root", salt_hex, hex, "/root", "/bin/sh.lua", "*"),
        "}",
        "",
      }, "\n")
      local pwd_ok, pwd_err = write_target_file("/etc/passwd", passwd)
      if not pwd_ok then
        eprint("install: writing /etc/passwd failed: " .. tostring(pwd_err))
      else
        ok("wrote /etc/passwd (root account, admin caps)")
        local sec = table.concat({
          "-- /etc/security.cfg — kernel security policy.",
          "-- Set up by the installer. Edit if you need a recovery boot",
          "-- (enforce=false) — but then anyone with shell access can",
          "-- bypass cap.check.",
          "return {",
          "  enforce = true,",
          "  default_user = \"root\",",
          "}",
          "",
        }, "\n")
        local sec_ok, sec_err = write_target_file("/etc/security.cfg", sec)
        if sec_ok then
          ok("flipped /etc/security.cfg → enforce=true")
        else
          eprint("install: writing /etc/security.cfg failed: " .. tostring(sec_err))
        end
      end
    else
      eprint("install: setup-root: " .. tostring(req_err))
    end
  end
end

-- Optional EEPROM flash. We pull the minified BIOS source (whose path the
-- builder placed in mfst.bios) and overwrite the EEPROM with it. Skipped
-- unless --flash-eeprom was passed because flashing is one-way without a
-- spare EEPROM to restore the stock BIOS from.
if flash_eeprom and mfst.bios then
  local eeprom_addr = component.list("eeprom")()
  if not eeprom_addr then
    eprint("install: --flash-eeprom but no EEPROM component present")
  else
    local bios_src
    if local_root then
      local fs = require("filesystem")
      local h, herr = fs.open(local_root .. "/" .. mfst.bios, "r")
      if not h then eprint("install: cannot read " .. mfst.bios .. ": " .. tostring(herr))
      else
        local parts = {}
        while true do local d = h:read(4096); if not d or d == "" then break end; parts[#parts + 1] = d end
        h:close(); bios_src = table.concat(parts)
      end
    else
      bios_src = fetch_http(base_url .. "/" .. mfst.bios)
    end
    if bios_src then
      local sok, serr = pcall(invoke, eeprom_addr, "set", bios_src)
      if not sok then eprint("install: eeprom.set: " .. tostring(serr))
      else
        pcall(invoke, eeprom_addr, "setLabel", "OCOS BIOS")
        pcall(invoke, eeprom_addr, "setData", target_addr)
        ok("flashed EEPROM (" .. #bios_src .. " B)")
      end
    end
  end
end

ok(string.format("wrote %d files. Reboot to start OCOS.", total))
return 0
