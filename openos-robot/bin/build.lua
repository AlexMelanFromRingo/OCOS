-- build.lua — blueprint builder (OpenOS port).
--
-- Reads a plain-text blueprint and places blocks layer by layer.
-- Format:
--
--   3 4 2                  -- W L H header (width, length, height)
--   .A.A
--   AAAA                   -- layer 1 — A means slot 1
--   .A.A
--
--   .B.B
--   BBBB                   -- layer 2 — B means slot 2
--   .B.B
--
-- Characters: '.' or space → empty, A..P → slot 1..16. Layers are
-- separated by a blank line. The robot starts at (0, 0) and climbs
-- one layer at a time, placing downward.
--
-- Usage:
--   build <blueprint-file>

local args = {...}
if #args < 1 then
  io.stderr:write("usage: build <blueprint>\n"); return 2
end
local blueprint_path = args[1]

local nav_m = require("nav")

local nav, err = nav_m.new()
if not nav then io.stderr:write("build: " .. tostring(err) .. "\n"); return 1 end
local r = nav.r

local f, oerr = io.open(blueprint_path, "r")
if not f then
  io.stderr:write("build: cannot read " .. blueprint_path .. ": " .. tostring(oerr) .. "\n")
  return 1
end
local src = f:read("*a"); f:close()

local lines = {}
for ln in (src .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = ln end

local W, L, H = lines[1]:match("^(%d+)%s+(%d+)%s+(%d+)")
W, L, H = tonumber(W), tonumber(L), tonumber(H)
if not (W and L and H) then
  io.stderr:write("build: bad header (need 'W L H')\n"); return 1
end

local cells = {}
local row = 2
for y = 1, H do
  cells[y] = {}
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
        cells[y][z][x] = nil
      end
    end
    row = row + 1
  end
end

for y = 1, H do
  io.write(string.format("build: layer %d / %d\n", y, H))
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
        os.sleep(0)
      end
    end
  end
end
nav:home()
io.write(string.format("build: done — %d × %d × %d\n", W, L, H))
return 0
