-- /sys/lib/net/sock.lua — datagram sockets over modem/tunnel.
--
-- Each socket binds a port (or, on a tunnel, accepts the implicit channel)
-- and exposes:
--   :send(addr, ...)
--   :broadcast(...)
--   :recv(timeout)  -> {sender, port, distance, payload[]}, or nil on timeout
--   :close()
--
-- recv yields cooperatively via sched.wait so multiple processes can share
-- the modem peacefully.

local M = {}

local sched = require("k.sched")
local ipc   = require("k.ipc")
local modem = require("drv.modem")

local Socket = {}
Socket.__index = Socket

function Socket:send(addr, ...) return modem.send(addr, self.port, ...) end
function Socket:broadcast(...)  return modem.broadcast(self.port, ...) end
function Socket:close()
  if self.handle then ipc.unsubscribe(self.handle); self.handle = nil end
  if self.port and self._opened then modem.close(self.port) end
end

function Socket:recv(timeout)
  -- The sub-callback enqueues messages; recv yields until queue non-empty.
  local SIGNAL = "__sock_" .. self.port
  local q = self.queue
  local deadline = timeout and (computer.uptime() + timeout) or nil
  while #q == 0 do
    if deadline and computer.uptime() >= deadline then return nil end
    local remaining = deadline and (deadline - computer.uptime()) or math.huge
    sched.wait(function(name) return name == SIGNAL end, remaining)
  end
  return table.remove(q, 1)
end

function M.bind(port)
  local self = setmetatable({ port = port, queue = {}, _opened = false }, Socket)
  local SIGNAL = "__sock_" .. port
  local opened = modem.open(port)
  if opened ~= nil then self._opened = (opened == true) end
  self.handle = ipc.subscribe("net.message", function(msg)
    if msg.port == port or modem.address and select(2, modem.address()) == "tunnel" then
      self.queue[#self.queue + 1] = msg
      computer.pushSignal(SIGNAL)
    end
  end)
  return self
end

return M
