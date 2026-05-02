-- /sys/k/ipc.lua — typed publish/subscribe channels.
--
-- channel names are strings; payloads are tables. handlers receive
-- (payload, meta) where meta = { time, channel }.
-- Subscriptions return an opaque token usable for unsubscribe.

local M = {}

local subs                                       -- {channel -> {token -> {fn, once}}}
local seq

function M.init()
  subs = {}
  seq = 0
end

function M.subscribe(channel, fn, opts)
  opts = opts or {}
  seq = seq + 1
  subs[channel] = subs[channel] or {}
  subs[channel][seq] = { fn = fn, once = opts.once == true }
  return { ch = channel, token = seq }
end

function M.unsubscribe(handle)
  if not handle then return end
  local ch = subs[handle.ch]
  if ch then ch[handle.token] = nil end
end

function M.publish(channel, payload)
  local listeners = subs[channel]
  if not listeners then return 0 end
  local meta = { time = computer.uptime(), channel = channel }
  local delivered = 0
  -- Snapshot to allow handlers to unsubscribe while we iterate.
  local snap = {}
  for tok, sub in pairs(listeners) do snap[tok] = sub end
  for tok, sub in pairs(snap) do
    local ok, err = pcall(sub.fn, payload, meta)
    if not ok then
      -- avoid hard failure on bad subscribers; log via require to dodge cycle
      local log = require("k.log")
      log.warn("ipc", "subscriber error on " .. channel .. ": " .. tostring(err))
    end
    if sub.once then listeners[tok] = nil end
    delivered = delivered + 1
  end
  return delivered
end

function M.channels()
  local names = {}
  for ch in pairs(subs) do names[#names + 1] = ch end
  table.sort(names)
  return names
end

return M
