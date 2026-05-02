-- /sys/std/io.lua — process-aware io binding.
--
-- Every process gets its own `io` table whose stdin/stdout/stderr are bound
-- to that process's streams. `proc.exec` builds one of these and injects it
-- into the loaded chunk's environment so commands see a familiar Lua-like
-- io library while staying fully sandboxed.

local M = {}

local fstream = require("std.fstream")

function M.bind(streams)
  -- streams = { stdin = Stream, stdout = Stream, stderr = Stream }
  local t = {
    stdin  = streams.stdin,
    stdout = streams.stdout,
    stderr = streams.stderr,
  }
  function t.write(...)
    return t.stdout:write(...)
  end
  function t.read(...)
    return t.stdin:read(...)
  end
  function t.lines(path)
    if path then
      local s, err = fstream.open(path, "r")
      if not s then return error(err, 2) end
      return function()
        local l = s:read("l")
        if l == nil then s:close() end
        return l
      end
    end
    return t.stdin:lines("l")
  end
  function t.open(path, mode) return fstream.open(path, mode or "r") end
  function t.input()  return t.stdin  end
  function t.output() return t.stdout end
  return t
end

function M.print_for(io_tbl)
  return function(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    io_tbl.stdout:write(table.concat(parts, "\t"), "\n")
  end
end

return M
