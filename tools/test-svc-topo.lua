-- Standalone unit test for lib/svc/manager.topo_sort.
--
-- Reproduces the v0.2.1 boot-hang bug: uid declares
-- `after = {"logd", "sessiond"}`, sessiond is excluded from the
-- autostart set under GUI mode, and the old topo_sort wrote to a
-- nil entry in `edges_to[sessiond]`. The fixed version drops edges
-- to non-member dependencies.
--
-- Run with: lua5.3 tools/test-svc-topo.lua

package.path = package.path .. ";src/sys/?.lua;src/sys/?/init.lua"

-- Minimal stubs for the OC globals manager.lua imports through requires.
package.preload["k.sched"] = function() return { spawn = function() end } end
package.preload["k.exec"]  = function() return { exec = function() return { id = 1 } end } end
package.preload["k.vfs"]   = function() return {
  isdir = function() return true end,
  list  = function() return {} end,
  read_all = function() return nil end,
} end
package.preload["k.ipc"]   = function() return {
  publish = function() end,
  subscribe = function() return {} end,
} end
package.preload["k.log"]   = function() return {
  info = function() end, warn = function() end, error = function() end,
  debug = function() end,
} end
package.preload["std.stream"] = function() return { null = function() return {} end } end

_G.computer  = { uptime = function() return 0 end }
_G.component = setmetatable({}, { __index = function() return function() end end })

local mgr = require("lib.svc.manager")

local function fail(msg) print("FAIL: " .. msg); os.exit(1) end

-- Test 1: trivial linear chain.
local services = {
  logd     = { unit = { id = "logd",     after = {},                       autostart = true } },
  sessiond = { unit = { id = "sessiond", after = { "logd" },                autostart = true } },
  uid      = { unit = { id = "uid",      after = { "logd", "sessiond" },   autostart = true } },
}
mgr._inject_services(services)
local order, err = mgr._topo_sort({ "logd", "sessiond", "uid" })
if not order then fail("linear chain: " .. tostring(err)) end
local pos = {}; for i, id in ipairs(order) do pos[id] = i end
if not (pos.logd < pos.sessiond and pos.sessiond < pos.uid) then
  fail("order wrong: " .. table.concat(order, ","))
end
print("PASS linear chain → " .. table.concat(order, ", "))

-- Test 2: GUI-mode regression — sessiond is loaded but NOT in the
-- autostart set. uid still declares `after = {..., sessiond}`. The old
-- topo crashed; the fix should drop the dangling edge and return
-- {logd, uid}.
order, err = mgr._topo_sort({ "logd", "uid" })
if not order then fail("gui-mode regression: " .. tostring(err)) end
pos = {}; for i, id in ipairs(order) do pos[id] = i end
if not (pos.logd and pos.uid) then fail("missing entries: " .. table.concat(order, ",")) end
if not (pos.logd < pos.uid) then fail("wrong order: " .. table.concat(order, ",")) end
print("PASS gui mode (sessiond disabled) → " .. table.concat(order, ", "))

-- Test 3: cycle detection still works.
services.a = { unit = { id = "a", after = { "b" }, autostart = true } }
services.b = { unit = { id = "b", after = { "a" }, autostart = true } }
mgr._inject_services(services)
order, err = mgr._topo_sort({ "a", "b" })
if order then fail("expected cycle error, got " .. table.concat(order, ",")) end
if not (err and err:find("cycle", 1, true)) then fail("missing cycle err: " .. tostring(err)) end
print("PASS cycle detection: " .. err)

print("all topo_sort tests passed")
