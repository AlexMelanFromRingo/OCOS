-- install.lua — copy robot scripts into the user's library / bin dirs.
--
-- Run from the floppy:
--
--     /mnt/<addr>/install.lua
--
-- or, if you've already cd'd into the mount:
--
--     ./install.lua
--
-- The installer copies `lib/*.lua` into `/home/lib/` and `bin/*.lua`
-- into `/home/bin/`. Both directories are part of the OpenOS default
-- LUA_PATH and PATH, so after installation the commands `farm`,
-- `quarry`, `mine`, `tunnel`, `stair`, `tree`, `fill`, `build`, and
-- `sort` are immediately on the shell's path.

local fs       = require("filesystem")
local shell    = require("shell")
local process  = require("process")

local function die(msg)
  io.stderr:write("install: " .. msg .. "\n"); os.exit(1)
end

local function source_dir()
  -- process.running() returns "(/mnt/abc/install.lua)" — strip the
  -- filename to get the directory the floppy is mounted at.
  local path = process.running()
  if not path then die("cannot determine script path") end
  return fs.path(path)
end

local SRC = source_dir()
local DST_LIB = "/home/lib"
local DST_BIN = "/home/bin"

local LIB_FILES = { "nav.lua", "path.lua" }
local BIN_FILES = {
  "farm.lua", "quarry.lua", "mine.lua", "tunnel.lua", "stair.lua",
  "tree.lua", "fill.lua", "build.lua", "sort.lua",
}

local function ensure_dir(dir)
  if fs.exists(dir) then
    if not fs.isDirectory(dir) then die(dir .. " exists and is not a directory") end
  else
    local ok, err = fs.makeDirectory(dir)
    if not ok then die("mkdir " .. dir .. ": " .. tostring(err)) end
  end
end

local function copy(src, dst)
  if fs.exists(dst) then fs.remove(dst) end
  local ok, err = fs.copy(src, dst)
  if not ok then die("copy " .. src .. " → " .. dst .. ": " .. tostring(err)) end
end

ensure_dir(DST_LIB)
ensure_dir(DST_BIN)

io.write("install: source = " .. SRC .. "\n")

for _, name in ipairs(LIB_FILES) do
  local src = fs.concat(SRC, "lib", name)
  if not fs.exists(src) then die("missing source file: " .. src) end
  local dst = fs.concat(DST_LIB, name)
  copy(src, dst)
  io.write("  lib  " .. name .. "\n")
end

for _, name in ipairs(BIN_FILES) do
  local src = fs.concat(SRC, "bin", name)
  if not fs.exists(src) then die("missing source file: " .. src) end
  local dst = fs.concat(DST_BIN, name)
  copy(src, dst)
  io.write("  bin  " .. name .. "\n")
end

io.write("install: done. Commands available:\n")
io.write("  farm  quarry  mine  tunnel  stair  tree  fill  build  sort\n")
io.write("Run any of them with --help (or read each script's header).\n")
return 0
