-- /sys/lib/auth/audit.lua — append-only audit log.
--
-- Every cap.deny / cap.grant / login / logout / sudo event lands in
-- /var/log/audit.log on the writable mount, with a fixed line format that
-- log.audit can still grep.

local M = {}

local vfs = require("k.vfs")

local function pick_path()
  for _, m in ipairs(vfs.mounts()) do
    if m.prefix:sub(1, 5) == "/mnt/" then
      pcall(vfs.mkdir, m.prefix .. "/var")
      pcall(vfs.mkdir, m.prefix .. "/var/log")
      return m.prefix .. "/var/log/audit.log"
    end
  end
end

local function quote(s) return string.format("%q", tostring(s)) end

function M.write(record)
  local p = pick_path(); if not p then return end
  local h = vfs.open(p, "a"); if not h then return end
  local fields = { string.format("ts=%.3f", computer.uptime()) }
  if record.kind   then fields[#fields + 1] = "kind="    .. record.kind end
  if record.user   then fields[#fields + 1] = "user="    .. quote(record.user) end
  if record.action then fields[#fields + 1] = "action="  .. quote(record.action) end
  if record.target then fields[#fields + 1] = "target="  .. quote(record.target) end
  if record.detail then fields[#fields + 1] = "detail="  .. quote(record.detail) end
  h:write(table.concat(fields, " ") .. "\n")
  h:close()
end

return M
