local invoke = component.invoke
local function ci(addr, method, ...)
local r = table.pack(pcall(invoke, addr, method, ...))
if not r[1] then return nil, r[2] end
return table.unpack(r, 2, r.n)
end
local gpu = component.list("gpu")()
local screen = component.list("screen")()
if gpu and screen then ci(gpu, "bind", screen) end
local function w() local x, y = ci(gpu, "getResolution"); return x or 80, y or 25 end
local function fill(c)
if not gpu then return end
ci(gpu, "setBackground", c or 0x000000)
local sw, sh = w(); ci(gpu, "fill", 1, 1, sw, sh, " ")
end
local function put(x, y, s, fg)
if not gpu then return end
ci(gpu, "setForeground", fg or 0xCCCCCC)
ci(gpu, "set", x, y, s)
end
local BIOS_VER = "0.2"
local function splash()
fill(0x000A14)
put(2, 2, "OCOS BIOS " .. BIOS_VER, 0xCCCCFF)
end
local function panic(msg, detail)
fill(0x1A0000)
put(2, 2, "OCOS BIOS " .. BIOS_VER .. " — boot failed", 0xFF6666)
put(2, 4, tostring(msg or "unknown"), 0xFFFFFF)
if detail then put(2, 5, tostring(detail), 0xCCCCCC) end
put(2, 7, "no bootable medium — insert a disk and reset.", 0x888888)
while true do computer.pullSignal(60) end
end
local eeprom = component.list("eeprom")()
if eeprom then ci(eeprom, "setLabel", "OCOS BIOS") end
local function read_boot_data()
if not eeprom then return {} end
local raw = ci(eeprom, "getData") or ""
if raw == "" then return {} end
local fn = load("return " .. raw, "=boot.cfg", "t", {})
if fn then
local ok, t = pcall(fn)
if ok and type(t) == "table" then return t end
end
return { fs = raw }
end
local function read_all(addr, path)
local h, err = ci(addr, "open", path)
if not h then return nil, err end
local parts = {}
while true do
local chunk = ci(addr, "read", h, math.maxinteger or math.huge)
if not chunk then break end
parts[#parts + 1] = chunk
end
ci(addr, "close", h)
return table.concat(parts)
end
local function exists(addr, path) return ci(addr, "exists", path) and true or false end
local function score(addr)
if exists(addr, "/.ocos-version") then return 2 end
if exists(addr, "/init.lua") then return 1 end
return 0
end
local function pick_fs(preferred)
if preferred and exists(preferred, "/init.lua") then return preferred end
local best, best_score = nil, 0
for addr in component.list("filesystem") do
local s = score(addr)
if s > best_score then best, best_score = addr, s end
end
return best
end
splash()
local cfg = read_boot_data()
if cfg.mode then _G._OCOS_BOOT_MODE = tostring(cfg.mode) end
local fs_addr = pick_fs(cfg.fs)
if not fs_addr then panic("no bootable medium found") end
local kernel_path = cfg.kernel or "/init.lua"
local src, err = read_all(fs_addr, kernel_path)
if not src then panic("cannot read " .. kernel_path, err) end
computer.getBootAddress = function() return fs_addr end
computer.setBootAddress = function(addr)
if eeprom then ci(eeprom, "setData", addr or "") end
fs_addr = addr
end
local fn, lerr = load(src, "=" .. kernel_path)
if not fn then panic("kernel load: " .. tostring(lerr)) end
computer.beep(1200, 0.05)
return fn()
