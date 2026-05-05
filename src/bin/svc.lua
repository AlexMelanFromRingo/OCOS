-- /bin/svc.lua — query and control system services.
local args = ...
local svc = require("lib.svc.manager")

local function print_table(rows, headers)
  local widths = {}
  for i, h in ipairs(headers) do widths[i] = #h end
  for _, r in ipairs(rows) do
    for i, v in ipairs(r) do widths[i] = math.max(widths[i], #tostring(v)) end
  end
  local function fmt(row)
    local parts = {}
    for i, v in ipairs(row) do parts[i] = string.format("%-" .. widths[i] .. "s", tostring(v)) end
    return table.concat(parts, "  ")
  end
  print(fmt(headers))
  for _, r in ipairs(rows) do print(fmt(r)) end
end

local cmd = args[1] or "list"
if cmd == "list" then
  local rows = {}
  for _, s in ipairs(svc.list()) do
    rows[#rows + 1] = { s.id, s.state, s.pid or "-", s.restart_count, s.description or "" }
  end
  print_table(rows, { "ID", "STATE", "PID", "RESTARTS", "DESC" })
  return 0
elseif cmd == "status" then
  local id = args[2] or io.stderr:write("usage: svc status <id>\n") or nil
  if not id then return 2 end
  local s = svc.status(id)
  if not s then io.stderr:write("svc: no such service: " .. id .. "\n"); return 1 end
  print(string.format("id          : %s",   s.id))
  print(string.format("description : %s",   s.description or ""))
  print(string.format("state       : %s",   s.state))
  print(string.format("pid         : %s",   tostring(s.pid)))
  print(string.format("restarts    : %d",   s.restart_count))
  print(string.format("started_at  : %s",   tostring(s.started_at)))
  if s.last_error then print("last_error  : " .. tostring(s.last_error)) end
  return 0
elseif cmd == "start" then
  local id = args[2] or io.stderr:write("usage: svc start <id>\n") or nil
  if not id then return 2 end
  local p, err = svc.start(id)
  if not p then io.stderr:write("svc: " .. tostring(err) .. "\n"); return 1 end
  print("started: " .. id)
  return 0
elseif cmd == "stop" then
  local id = args[2] or io.stderr:write("usage: svc stop <id>\n") or nil
  if not id then return 2 end
  local ok, err = svc.stop(id)
  if not ok then io.stderr:write("svc: " .. tostring(err) .. "\n"); return 1 end
  print("stopped: " .. id)
  return 0
end
io.stderr:write("usage: svc {list|status <id>|start <id>|stop <id>}\n")
return 2
