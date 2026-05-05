-- /sys/svc/logd.lua — kernel-log persister.
--
-- Subscribes to the in-RAM ring buffer's live tap and appends each entry
-- to /var/log/dmesg.log on the first writable mount, rotating when the
-- file grows past 64 KiB. Exits when its `svc.stop.logd` channel fires.

local sched = require("k.sched")
local log   = require("k.log")
local vfs   = require("k.vfs")
local ipc   = require("k.ipc")

local MAX_BYTES = 64 * 1024
local KEEP      = 4

local function pick_log_path()
  for _, m in ipairs(vfs.mounts()) do
    if m.prefix:sub(1, 5) == "/mnt/" then
      pcall(vfs.mkdir, m.prefix .. "/var")
      pcall(vfs.mkdir, m.prefix .. "/var/log")
      return m.prefix .. "/var/log/dmesg.log"
    end
  end
end

local function rotate(path)
  for i = KEEP - 1, 1, -1 do
    local from, to = path .. "." .. i, path .. "." .. (i + 1)
    if vfs.exists(from) then pcall(vfs.rename, from, to) end
  end
  if vfs.exists(path) then pcall(vfs.rename, path, path .. ".1") end
end

local function append_line(path, line)
  local size = vfs.size(path) or 0
  if size + #line > MAX_BYTES then rotate(path) end
  local h, err = vfs.open(path, "a")
  if not h then return nil, err end
  h:write(line)
  h:close()
  return true
end

local function format_entry(e)
  return string.format("[%8.3f] %s %s: %s\n", e.time, e.level, e.tag, e.msg)
end

local path = pick_log_path()
if not path then
  log.warn("logd", "no writable mount; logd is exiting")
  return 0
end

-- Catch up: write everything currently buffered.
for _, e in ipairs(log.entries()) do append_line(path, format_entry(e)) end

-- Live tap. The subscribe callback runs in whichever coroutine published the
-- entry, so we keep its body trivial — just enqueue.
local pending = {}
local NOTIFY = "__logd_entry"
local STOP   = "__logd_stop"
local stopping = false

local log_handle  = log.subscribe(nil, function(entry)
  pending[#pending + 1] = entry
  computer.pushSignal(NOTIFY)
end)
local stop_handle = ipc.subscribe("svc.stop.logd", function()
  stopping = true; computer.pushSignal(STOP)
end)

while not stopping do
  sched.wait(function(name) return name == NOTIFY or name == STOP end, math.huge)
  while #pending > 0 do
    append_line(path, format_entry(table.remove(pending, 1)))
  end
end

log.unsubscribe(log_handle)
ipc.unsubscribe(stop_handle)
return 0
