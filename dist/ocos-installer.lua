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

local args = { ... }

local component = component or require("component")
local computer  = computer  or require("computer")
local invoke = component.invoke

local DEFAULT_BASE = "https://raw.githubusercontent.com/AlexMelanFromRingo/OCOS/main"

local function eprint(s) io.stderr:write(s .. "\n") end
local function ok(s)     io.write("[ok] " .. s .. "\n") end

-- ---- arg parsing -------------------------------------------------------

local target_prefix, base_url, local_root
do
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--local" then
      local_root = args[i + 1]
      if not local_root then eprint("--local needs a path"); return 2 end
      i = i + 2
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

if computer.setBootAddress then
  computer.setBootAddress(target_addr)
  ok("set boot address to " .. target_addr:sub(1, 8))
end

ok(string.format("wrote %d files. Reboot to start OCOS.", total))
return 0
