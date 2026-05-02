-- /sys/std/fstream.lua — Stream wrapper around a vfs file handle.

local M = {}

local stream = require("std.stream")
local vfs    = require("k.vfs")

function M.open(path, mode)
  local h, err = vfs.open(path, mode or "r")
  if not h then return nil, err end
  return stream.new {
    _read  = function(_, n) return h:read(n) end,
    _write = function(self, s) return h:write(s) and self or nil end,
    _close = function() return h:close() end,
    _seek  = function(_, whence, off) return h:seek(whence, off) end,
  }
end

return M
