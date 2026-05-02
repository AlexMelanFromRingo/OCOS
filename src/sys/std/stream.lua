-- /sys/std/stream.lua — base stream type used by every I/O endpoint.
--
-- A stream owns no backing storage of its own; concrete types provide
-- `_read`/`_write`/`_close` and the base wraps them with a small line buffer
-- so `read("l")` and `lines()` work uniformly across pipes, tty and files.
--
-- The interface is the same kind of layered design Lua's `io` library uses:
-- raw byte reads/writes underneath, line-aware helpers on top.

local M = {}

local Stream = {}
Stream.__index = Stream

function Stream:read(fmt)
  fmt = fmt or "l"
  if type(fmt) == "number" then return self:_read(fmt) end
  if fmt == "*a" or fmt == "a" then
    local parts = {}
    while true do
      local chunk = self:_read(4096)
      if not chunk or chunk == "" then break end
      parts[#parts + 1] = chunk
    end
    return table.concat(parts)
  elseif fmt == "*l" or fmt == "l" or fmt == "*L" or fmt == "L" then
    local keep_eol = fmt:sub(-1) == "L"
    local buf = self._linebuf or ""
    while true do
      local nl = buf:find("\n", 1, true)
      if nl then
        local line = buf:sub(1, nl - (keep_eol and 0 or 1))
        self._linebuf = buf:sub(nl + 1)
        return line
      end
      local chunk = self:_read(256)
      if not chunk or chunk == "" then
        if buf == "" then self._linebuf = ""; return nil end
        self._linebuf = ""
        return buf
      end
      buf = buf .. chunk
    end
  elseif fmt == "*n" or fmt == "n" then
    error("stream:read('n') not supported", 2)
  end
  error("invalid stream:read format: " .. tostring(fmt), 2)
end

function Stream:write(...)
  for i = 1, select("#", ...) do
    local ok, err = self:_write(tostring((select(i, ...))))
    if not ok then return nil, err end
  end
  return self
end

function Stream:lines(...)
  local args = table.pack(...)
  return function() return self:read(args[1] or "l") end
end

function Stream:close()
  if self._closed then return true end
  self._closed = true
  if self._close then return self:_close() end
  return true
end

function Stream:flush()
  if self._flush then return self:_flush() end
  return self
end

function Stream:is_closed() return self._closed == true end
function Stream:seek() return nil, "stream is not seekable" end

function M.new(impl)
  -- impl provides _read / _write / _close / _flush; missing methods become
  -- no-ops or "not supported" errors via the corresponding Stream methods.
  local s = setmetatable({}, Stream)
  for k, v in pairs(impl) do s[k] = v end
  return s
end

function M.null()
  -- A stream that immediately returns EOF on read and accepts writes silently.
  -- Useful when wiring "/dev/null" semantics into a process's stdin or stderr.
  return M.new {
    _read  = function() return nil end,
    _write = function(self) return self end,
  }
end

M.Stream = Stream
return M
