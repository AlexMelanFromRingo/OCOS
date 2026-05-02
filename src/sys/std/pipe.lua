-- /sys/std/pipe.lua — in-memory pipe between two cooperative processes.
--
-- The reader-side blocks on sched.wait until data arrives or the pipe closes.
-- The writer-side enqueues bytes and publishes a signal so the reader can
-- wake up. We use the IPC bus rather than direct coroutine.resume so the
-- scheduler stays the only place that drives processes.

local M = {}

local sched = require("k.sched")
local ipc   = require("k.ipc")
local stream = require("std.stream")

local _seq = 0
local function new_pipe()
  _seq = _seq + 1
  local id = _seq
  local channel = "pipe.wake." .. id
  local state = {
    id      = id,
    chunks  = {},                                -- queue of pending strings
    closed  = false,
    channel = channel,
  }

  local function enqueue(data)
    state.chunks[#state.chunks + 1] = data
    ipc.publish(channel, true)
  end

  local function dequeue(max)
    local head = state.chunks[1]
    if not head then return nil end
    if #head <= max then
      table.remove(state.chunks, 1)
      return head
    end
    state.chunks[1] = head:sub(max + 1)
    return head:sub(1, max)
  end

  local read_end = stream.new {
    _read = function(self, n)
      n = n or math.huge
      while #state.chunks == 0 and not state.closed do
        sched.wait(function(name) return name == "__pipe__" .. id end, math.huge)
      end
      return dequeue(n) or (state.closed and "" or nil)
    end,
    _close = function() state.closed = true; ipc.publish(channel, true); return true end,
  }
  local write_end = stream.new {
    _write = function(self, s)
      if state.closed then return nil, "broken pipe" end
      if s ~= "" then enqueue(s) end
      return self
    end,
    _close = function() state.closed = true; ipc.publish(channel, true); return true end,
  }

  -- The reader's sched.wait filter is by raw signal name. We hook the IPC
  -- channel and bridge it into a synthetic "__pipe__<id>" signal that the
  -- scheduler's filter machinery understands.
  ipc.subscribe(channel, function()
    computer.pushSignal("__pipe__" .. id)
  end)

  return read_end, write_end
end

M.new = new_pipe
return M
