-- /sys/lib/auth/audit.lua — append-only audit log.
--
-- Every cap.deny / cap.grant / login / logout / sudo event lands in
-- /var/log/audit.log on the writable mount, with a fixed line format that
-- log.audit can still grep.
--
-- The write path bypasses k.vfs and goes straight to the filesystem
-- component's invoke. Two reasons:
--
--   1. Recursion. cap.check audits a `cap.deny` event by calling
--      audit.write. If audit.write then took the vfs path, vfs.open
--      would call check_write_cap → cap.check → audit.write → ...
--      infinite recursion that locked up the boot menu under
--      enforce=true (the symptom: hangs after picking any mode).
--   2. Audit must succeed even when the calling process is denied
--      writes to /var/log itself — the whole point of the audit log
--      is to record denials, including ones for cap-restricted
--      processes that wouldn't be able to vfs.open their own audit.
--
-- The trade-off: audit lines bypass cap.enforce. That's fine because
-- the kernel writes them on behalf of the security subsystem, not on
-- behalf of the caller.
--
-- A re-entry guard keeps a single in-flight audit write from
-- triggering more audits via the cap-check chain (e.g. through a
-- component.invoke that itself routed through cap.check at a higher
-- layer).

local M = {}

local writing = false                                -- re-entry guard

local function pick_addr()
  if not _G.component or not _G.component.list then return nil end
  for addr in _G.component.list("filesystem") do
    local ok, ro = pcall(_G.component.invoke, addr, "isReadOnly")
    if ok and not ro then return addr end
  end
end

local function ensure_dirs(addr)
  pcall(_G.component.invoke, addr, "makeDirectory", "/var")
  pcall(_G.component.invoke, addr, "makeDirectory", "/var/log")
end

local function quote(s) return string.format("%q", tostring(s)) end

function M.write(record)
  if writing then return end                         -- short-circuit recursion
  writing = true

  local addr = pick_addr()
  if not addr then writing = false; return end
  ensure_dirs(addr)

  local fields = { string.format("ts=%.3f", computer.uptime()) }
  if record.kind   then fields[#fields + 1] = "kind="    .. record.kind end
  if record.user   then fields[#fields + 1] = "user="    .. quote(record.user) end
  if record.action then fields[#fields + 1] = "action="  .. quote(record.action) end
  if record.target then fields[#fields + 1] = "target="  .. quote(record.target) end
  if record.detail then fields[#fields + 1] = "detail="  .. quote(record.detail) end
  local line = table.concat(fields, " ") .. "\n"

  local ok, h = pcall(_G.component.invoke, addr, "open", "/var/log/audit.log", "a")
  if ok and h then
    pcall(_G.component.invoke, addr, "write", h, line)
    pcall(_G.component.invoke, addr, "close", h)
  end
  writing = false
end

return M
