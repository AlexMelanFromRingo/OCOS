-- /sys/k/signal.lua — central signal pump.
--
-- The scheduler is the only place that calls `computer.pullSignal`. This
-- module exposes:
--   signal.pull(timeout)       blocking call delegated by the scheduler
--   signal.dispatch(name, ...) for synthetic signals (also publishes to IPC)
-- and on init it subscribes nothing — actual fan-out happens via IPC after
-- /sys/k/ipc.lua is up. boot.lua wires the relationship explicitly.

local M = {}

local ipc                                        -- lazy-loaded after init order

function M.init()
  -- Nothing to do here for now; left as a hook for stats counters later.
end

function M.bind_ipc(ipc_module)
  ipc = ipc_module
end

function M.pull(timeout)
  -- Returning name + variadic preserves the OC contract. We deliberately do
  -- NOT translate to event objects here; that's the scheduler's job.
  return computer.pullSignal(timeout)
end

function M.publish(name, ...)
  if ipc then
    ipc.publish("oc.signal." .. name, table.pack(...))
  end
end

function M.push(name, ...)
  -- Re-emit a synthetic signal as if it came from the host queue. Useful for
  -- internal events that should reach the same listeners as hardware events.
  computer.pushSignal(name, ...)
end

return M
