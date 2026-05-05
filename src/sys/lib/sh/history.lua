-- /sys/lib/sh/history.lua — persistent shell history.
--
-- Backed by a file on the writable VFS. The shell loads it on startup
-- and appends each accepted line atomically (via vfs.read_all + write_all
-- — there is no append-only stream API, but the writes are tiny).
--
-- Public API:
--   history.open(path, limit?) -> hist
--     hist:all()                array of strings (oldest first)
--     hist:record(line)         drop consecutive duplicates, trim to limit,
--                               flush to disk

local M = {}

local vfs = require("k.vfs")

local DEFAULT_LIMIT = 1000

local function read_lines(path)
  if not vfs.exists(path) then return {} end
  local data = vfs.read_all(path) or ""
  local lines = {}
  for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then lines[#lines + 1] = line end
  end
  return lines
end

local function ensure_dir(path)
  local parent = path:match("(.*)/[^/]+$")
  if not parent or parent == "" or vfs.exists(parent) then return end
  ensure_dir(parent)
  pcall(vfs.mkdir, parent)
end

local Hist = {}
Hist.__index = Hist

function Hist:all() return self.entries end

function Hist:record(line)
  if not line or line == "" then return end
  local n = #self.entries
  if self.entries[n] == line then return end
  self.entries[n + 1] = line
  if #self.entries > self.limit then
    table.remove(self.entries, 1)
  end
  ensure_dir(self.path)
  pcall(vfs.write_all, self.path, table.concat(self.entries, "\n") .. "\n")
end

function M.open(path, limit)
  return setmetatable({
    path    = path,
    limit   = limit or DEFAULT_LIMIT,
    entries = read_lines(path),
  }, Hist)
end

return M
