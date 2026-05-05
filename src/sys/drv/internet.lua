-- /sys/drv/internet.lua — wraps the OC internet card.
--
-- Provides:
--   net.has_internet()           true if a card is attached and HTTP enabled
--   net.http_request(url, opts)  blocks until the response is received,
--                                returns body, status, headers (or nil, err)
--   net.tcp_connect(host, port)  returns a Stream-shaped object, or nil, err
--
-- The HTTP path uses the card's request handle: we poll read() until the
-- card returns nil (EOF). For correctness under the 5-s watchdog we yield
-- between reads and bound the total wait via opts.timeout (default 30s).

local M = {}

local sched   = require("k.sched")
local stream  = require("std.stream")
local log     = require("k.log")

local function pick_card()
  local addr = component.list("internet")()
  if not addr then return nil end
  return component.proxy(addr), addr
end

function M.init()
  local card, addr = pick_card()
  if card then log.info("internet", "card available: " .. addr:sub(1, 8)) end
end

function M.has_internet()
  local card = pick_card()
  return card and card.isHttpEnabled and card.isHttpEnabled() == true
end

local function read_handle_to_string(handle, timeout)
  local deadline = computer.uptime() + (timeout or 30)
  local parts = {}
  while computer.uptime() < deadline do
    local chunk, err = handle.read(8192)
    if chunk == nil then
      if err then return nil, tostring(err) end
      break
    end
    if chunk == "" then sched.sleep(0.05) else parts[#parts + 1] = chunk end
  end
  if computer.uptime() >= deadline then return nil, "timeout" end
  return table.concat(parts)
end

function M.http_request(url, opts)
  opts = opts or {}
  local card, addr = pick_card()
  if not card then return nil, "no internet card" end
  if card.isHttpEnabled and not card.isHttpEnabled() then
    return nil, "http disabled by host"
  end
  local handle, err = card.request(url, opts.body, opts.headers)
  if not handle then return nil, "request: " .. tostring(err) end
  -- The card's handle exposes finishConnect()/response()/read()/close().
  local started = computer.uptime()
  local timeout = opts.timeout or 30
  while not handle.finishConnect() do
    if computer.uptime() - started > timeout then
      handle.close(); return nil, "connect timeout"
    end
    sched.sleep(0.1)
  end
  local status, msg, headers = handle.response()
  local body, berr = read_handle_to_string(handle, timeout)
  handle.close()
  if not body then return nil, berr end
  return body, status, headers
end

local function wrap_tcp_handle(handle)
  local closed = false
  local read_buffer = ""
  return stream.new {
    _read = function(self, n)
      if closed and read_buffer == "" then return nil end
      while not closed and #read_buffer < (n or 1) do
        local chunk = handle.read(n or 4096)
        if chunk == nil then closed = true; break end
        if chunk == "" then sched.sleep(0.05) else read_buffer = read_buffer .. chunk end
      end
      local out = read_buffer:sub(1, n or #read_buffer)
      read_buffer = read_buffer:sub((n or #read_buffer) + 1)
      if out == "" and closed then return nil end
      return out
    end,
    _write = function(s, data)
      if closed then return nil, "closed" end
      handle.write(data)
      return s
    end,
    _close = function()
      if not closed then handle.close(); closed = true end
      return true
    end,
  }
end

function M.tcp_connect(host, port, timeout)
  local card = pick_card()
  if not card or not card.connect then return nil, "no tcp-capable card" end
  if card.isTcpEnabled and not card.isTcpEnabled() then return nil, "tcp disabled" end
  local handle, err = card.connect(host, port)
  if not handle then return nil, "connect: " .. tostring(err) end
  local started = computer.uptime()
  while not handle.finishConnect() do
    if computer.uptime() - started > (timeout or 30) then
      handle.close(); return nil, "connect timeout"
    end
    sched.sleep(0.05)
  end
  return wrap_tcp_handle(handle)
end

return M
