-- /bin/build.lua — blueprint builder.
--
-- Reads a plain-text blueprint and places blocks layer by layer. The
-- format is intentionally simple so you can author it in a text
-- editor without a tool:
--
--   3 4 2                     -- W L H  (width, length, height)
--   .A.A
--   AAAA                      -- layer 1 — A is "block from slot 1"
--   .A.A
--
--   .B.B
--   BBBB                      -- layer 2 — B is "block from slot 2"
--   .B.B
--
-- A line of just whitespace separates layers (blank line). Each
-- character in a row is one cell:
--
--   . / space   leave empty
--   A          place from slot 1
--   B          place from slot 2
--   …          letters A..P map to slots 1..16
--
-- The robot starts at (0, 0) at the build's base height and works
-- upward layer by layer.
--
-- Usage:
--   build <blueprint-file>

local args = ...
if #args < 1 then
  io.stderr:write("usage: build <blueprint>\n"); return 2
end
local blueprint_path = args[1]

local nav_m = require("lib.robot.nav")
local sched = require("k.sched")
local vfs   = require("k.vfs")

local nav, err = nav_m.new()
if not nav then io.stderr:write("build: " .. tostring(err) .. "\n"); return 1 end
local r = nav.r

local src = vfs.read_all(blueprint_path)
if not src then
  io.stderr:write("build: cannot read " .. blueprint_path .. "\n"); return 1
end

-- Parse: header line "W L H" then H layers, each a (L+1)-line block
-- (L rows of width-W cells, separated by blank between layers).
local lines = {}
for ln in (src .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = ln end

local W, L, H = lines[1]:match("^(%d+)%s+(%d+)%s+(%d+)")
W, L, H = tonumber(W), tonumber(L), tonumber(H)
if not (W and L and H) then
  io.stderr:write("build: bad header (need 'W L H')\n"); return 1
end

-- Build a 3D table of slot-or-nil per cell.
local cells = {}
local row = 2
for y = 1, H do
  cells[y] = {}
  -- Skip leading blank lines between layers.
  while row <= #lines and lines[row]:match("^%s*$") do row = row + 1 end
  for z = 1, L do
    cells[y][z] = {}
    local line = lines[row] or ""
    for x = 1, W do
      local c = line:sub(x, x)
      if c == "." or c == " " or c == "" then
        cells[y][z][x] = nil
      elseif c >= "A" and c <= "P" then
        cells[y][z][x] = string.byte(c) - string.byte("A") + 1
      else
        cells[y][z][x] = nil                       -- unknown char → empty
      end
    end
    row = row + 1
  end
end

-- Build the structure layer by layer. For each occupied cell, drive
-- to (x, y, z+1) and placeDown (we stand one tile above the block
-- we're laying so the place_down lands the block at y).
for y = 1, H do
  io.stdout:write(string.format("build: layer %d / %d\n", y, H))
  -- Climb to layer y. y=1 is at altitude 1 (one above the base
  -- block we're laying at altitude 0).
  if not nav:goto_y(y) then break end
  for z = 1, L do
    for x = 1, W do
      local slot = cells[y][z][x]
      if slot then
        if not nav:goto_xz(x - 1, z - 1, false) then break end
        r.select(slot)
        if (r.count(slot) or 0) == 0 then
          io.stderr:write(string.format(
            "build: out of blocks in slot %d at (%d,%d,%d)\n", slot, x, y, z))
        else
          pcall(r.placeDown)
        end
        sched.sleep(0)
      end
    end
  end
end
nav:home()
io.stdout:write(string.format("build: done — %d × %d × %d\n", W, L, H))
return 0
