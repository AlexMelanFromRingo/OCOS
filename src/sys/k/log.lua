-- /sys/k/log.lua — kernel ring-buffer logger.
--
-- Public:
--   log.init(opts)
--   log.{trace,debug,info,warn,error,fatal}(tag, msg, kv?)
--   log.entries() -> array of {time, level, tag, msg, kv}
--   log.subscribe(level, fn) -> token   (live tap, used by logd later)
--   log.unsubscribe(token)
--
-- Entries are plain tables (Eris-safe). `kv` is an optional table of small
-- scalars; we never store userdata or live coroutines.

local M = {}

local LEVELS = { trace = 1, debug = 2, info = 3, warn = 4, error = 5, fatal = 6 }
local DEFAULT_THRESHOLD = LEVELS.debug

local ring                                       -- circular buffer of entries
local ring_size, ring_head, ring_count
local subs, sub_seq

local function push(level, tag, msg, kv)
  if (LEVELS[level] or 0) < DEFAULT_THRESHOLD then return end
  local entry = { time = computer.uptime(), level = level, tag = tag, msg = msg, kv = kv }
  ring_head = (ring_head % ring_size) + 1
  ring[ring_head] = entry
  if ring_count < ring_size then ring_count = ring_count + 1 end
  for _, sub in pairs(subs) do
    if not sub.level or LEVELS[level] >= LEVELS[sub.level] then
      pcall(sub.fn, entry)
    end
  end
end

function M.init(opts)
  opts = opts or {}
  ring_size = opts.ring_size or 256
  ring = {}
  ring_head = 0
  ring_count = 0
  subs = {}
  sub_seq = 0
  push("info", "log", "logger online (ring=" .. ring_size .. ")")
end

for level in pairs(LEVELS) do
  M[level] = function(tag, msg, kv) push(level, tag, msg, kv) end
end

function M.entries()
  local out = {}
  if ring_count == 0 then return out end
  local idx = (ring_head - ring_count) % ring_size + 1
  for i = 1, ring_count do
    out[i] = ring[((idx - 1 + i - 1) % ring_size) + 1]
  end
  return out
end

function M.subscribe(level, fn)
  sub_seq = sub_seq + 1
  subs[sub_seq] = { level = level, fn = fn }
  return sub_seq
end

function M.unsubscribe(token)
  subs[token] = nil
end

return M
