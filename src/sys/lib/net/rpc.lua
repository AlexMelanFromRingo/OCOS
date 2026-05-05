-- /sys/lib/net/rpc.lua — JSON-RPC 2.0 over modem sockets.
--
-- Server side:
--   rpc.serve(port, methods)  blocks while serving registered handlers.
-- Client side:
--   rpc.call(target_addr, port, method, params, timeout)
--
-- `methods` is { name = function(params, ctx) -> result | error("string") }.
-- Errors raised inside a handler become a JSON-RPC error response with
-- code -32000 and the error string as message.

local M = {}

local sock  = require("lib.net.sock")
local json  = require("lib.codec.json")
local sched = require("k.sched")

local function next_id(state)
  state.id = (state.id or 0) + 1
  return state.id
end

function M.call(target_addr, port, method, params, timeout)
  local state = M._client_state or { id = 0, sockets = {}, sock = nil }
  M._client_state = state
  if not state.sock then state.sock = sock.bind(port) end
  local id = next_id(state)
  local req = json.encode({ jsonrpc = "2.0", id = id, method = method, params = params or json.null })
  state.sock:send(target_addr, req)
  local deadline = computer.uptime() + (timeout or 5)
  while computer.uptime() < deadline do
    local msg = state.sock:recv(deadline - computer.uptime())
    if msg then
      local body = msg.payload[1]
      local parsed, perr = json.decode(body or "")
      if parsed and parsed.id == id then
        if parsed.error then return nil, parsed.error.message or "rpc error" end
        return parsed.result
      end
    end
  end
  return nil, "rpc timeout"
end

function M.serve(port, methods)
  local s = sock.bind(port)
  while true do
    local msg = s:recv()
    if msg then
      local body = msg.payload[1]
      local parsed, perr = json.decode(body or "")
      if parsed then
        local handler = methods[parsed.method]
        local response
        if not handler then
          response = { jsonrpc = "2.0", id = parsed.id,
                       error = { code = -32601, message = "method not found" } }
        else
          local ok, ret = pcall(handler, parsed.params, { sender = msg.sender })
          if ok then response = { jsonrpc = "2.0", id = parsed.id, result = ret }
          else response = { jsonrpc = "2.0", id = parsed.id,
                            error = { code = -32000, message = tostring(ret) } } end
        end
        s:send(msg.sender, json.encode(response))
      end
    end
  end
end

return M
