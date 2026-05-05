-- /sys/drv/modem.lua — wired/wireless network modem.
--
-- Republishes incoming `modem_message` signals onto a structured channel
-- `net.message` with named fields, and exposes a small send/broadcast API
-- that hides the choice between modem and tunnel cards.
--
-- Apps wanting raw access can still subscribe to `oc.signal.modem_message`.

local M = {}

local ipc = require("k.ipc")
local log = require("k.log")

local primary, primary_kind                       -- "modem" | "tunnel"

local function rebind()
  primary = nil
  for addr in component.list("modem") do primary, primary_kind = addr, "modem"; break end
  if not primary then
    for addr in component.list("tunnel") do primary, primary_kind = addr, "tunnel"; break end
  end
end

function M.init()
  rebind()
  ipc.subscribe("oc.signal.component_added",   function() rebind() end)
  ipc.subscribe("oc.signal.component_removed", function() rebind() end)

  ipc.subscribe("oc.signal.modem_message", function(args)
    -- args = {addr, sender, port, distance, ...payload}
    local payload = {}
    for i = 5, args.n or 0 do payload[i - 4] = args[i] end
    ipc.publish("net.message", {
      iface_addr = args[1], sender = args[2], port = args[3],
      distance = args[4], payload = payload,
    })
  end)
end

function M.open(port)
  if not primary then return nil, "no modem" end
  if primary_kind == "tunnel" then return true end       -- tunnel ignores ports
  return component.invoke(primary, "open", port)
end

function M.close(port)
  if not primary or primary_kind == "tunnel" then return true end
  return component.invoke(primary, "close", port)
end

function M.send(target_addr, port, ...)
  if not primary then return nil, "no modem" end
  if primary_kind == "tunnel" then
    return component.invoke(primary, "send", ...)
  end
  return component.invoke(primary, "send", target_addr, port, ...)
end

function M.broadcast(port, ...)
  if not primary then return nil, "no modem" end
  if primary_kind == "tunnel" then
    return component.invoke(primary, "send", ...)
  end
  return component.invoke(primary, "broadcast", port, ...)
end

function M.is_wireless()
  if not primary or primary_kind ~= "modem" then return false end
  local ok, w = pcall(component.invoke, primary, "isWireless")
  return ok and w == true
end

function M.address() return primary, primary_kind end

return M
