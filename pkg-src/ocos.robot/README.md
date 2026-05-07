# ocos.robot — autonomous robot tasks for OCOS

A bundle of nine CLI tools that turn an OpenComputers robot into a
farmer, miner, builder, sorter, or anything else you'd want a tireless
worker for. Designed to be installed only on robots — these tools
require the `robot` component and several of them require the
`inventory_controller` upgrade.

The package ships with no shared library code: it depends entirely on
the navigation primitives that already live in OCOS at
`/sys/lib/robot/nav.lua` and `/sys/lib/robot/path.lua`. Both libraries
are part of the core OS so that anyone can write their own robot
script without first installing this pack.

## Install

```sh
# Build the package on the dev host (already done in the repo, but
# this is how you'd rebuild after editing pkg-src/ocos.robot/bin/*).
tools/pack.py pkg-src/ocos.robot -o dist/ocos.robot

# On the target robot (must be running OCOS):
pkg install /path/to/dist/ocos.robot
```

After install, the nine commands below live in `/bin/` and are on the
default PATH.

## Architecture: why these scripts don't strand the robot

Two libraries do all the heavy lifting; every script in this pack
delegates to them.

### `lib.robot.nav` — coordinate-tracking navigation

The robot starts at `(0, 0, 0)` facing `+x`. Every successful
`forward / back / up / down / turn_*` call updates the bookkeeping.
Higher-level callers do not count steps; they ask `nav:goto_xz(x, z)`
or `nav:goto_xyz(x, y, z)` and the navigator figures out the moves.

`nav:home(retry_swing)` returns to the origin and re-faces the
starting direction. With `retry_swing=true` the navigator will swing
through obstructions on the way (gravel that fell in, cobblestone that
formed where lava met water during a long dig). Vertical retries are
capped at `MAX_VERTICAL_SWINGS = 8` so the robot can't wedge itself in
an infinite loop against a regenerating cobble fountain.

`nav:distance_home()` returns the Manhattan distance to `(0, 0, 0)` —
used by miners to budget energy honestly instead of guessing with a
flat 10 % cutoff.

### `lib.robot.path` — field-traversal iterators

`snake(W, H)`, `rows(W, H)`, `spiral(W, H)`. Every iterator yields
1-based `(x, z)` cell pairs covering the rectangle exactly once.

The classic "even-width snake doesn't return to origin" bug comes from
counting steps and turns inside the worker loop; the iterator-driven
design avoids it entirely. The selftest entry
`robot path snake covers W×H exactly once` pins this guarantee on
sizes including `4×4`, `4×5`, `5×4`, and `2×7`.

## The nine scripts

Default arguments shown after `=`; flag forms with no `=` are flags
(no value).

### `farm` — wheat / carrot / potato farmer

```
farm [-w W=9] [-h H=9] [--passes N | --forever]
```

**Setup:** robot on the field corner facing the long edge. Below: chest
for harvest. Above: chest with seeds. Slot 1 pre-loaded with at least
one seed. Loops indefinitely by default.

The robot snakes the field, swings the cell below to harvest, replants
from slot 1, and trips home when the inventory or energy runs low. On
each home visit it dumps slots 2..N into the chest below and refills
slot 1 from the chest above.

### `tree` — sapling row lumberjack

```
tree [-n COUNT=4] [-s SPACING=4] [--passes N | --forever]
```

**Setup:** row of `n` planted saplings spaced `s` blocks apart in the
+x direction; chest below the start tile for logs. The robot walks
each spot, detects a log via `compareDown` against slot 1 (= sapling),
climbs the trunk swinging up while there are blocks above, descends,
and replants.

### `mine` — strip-miner / shallow quarry

```
mine [-w W=9] [-l L=9] [-d D=16]
```

**Setup:** robot on the corner of the dig area, facing along the
length axis. Chest below the start tile.

Each layer: descend, snake the rectangle swinging down + up on every
cell, return to (0, 0) at the layer's end. When the inventory fills
the robot surfaces, dumps, and dives back to where it left off. Use
`mine` for shallow regular pits; for deep `D > 32` use `quarry`.

### `quarry` — deep 3D quarry with energy budgeting

```
quarry [-w W=9] [-l L=9] [-d D=64]
```

**Setup:** same as `mine`, but a *charger* above the start tile is
strongly recommended for any `D > 16`.

Differences vs `mine`:

* **Stays underground.** `quarry` only surfaces when the inventory is
  full or the energy reserve gets thin — not after every layer. Saves
  a lot of round-trip cost on deep digs.
* **Manhattan-distance energy reserve.** Instead of "surface at 10 %",
  `quarry` checks `energy < distance_home × MOVE_COST + RESERVE`
  before each cell. With `MOVE_COST = 60` and `RESERVE = 500` (tuned
  for vanilla OC defaults), the robot will surface from y = -50 with
  exactly enough juice to climb out and a small safety margin.
  Adjust the constants near the top of `quarry.lua` if your server
  uses non-default `robotExhaustionCost`.
* **Cobble-tolerant return.** `surface_and_dump` calls
  `nav:goto_y(0, true)` so the robot will break through any cobble
  that formed in the chimney while it was working below — typically
  caused by a lava+water junction in the wall.
* **Charger wait.** If the energy is still below the reserve after
  dumping, the robot sleeps in 5 s ticks until the charger has
  refilled to 90 %, then resumes work.

#### Why no special handling for falling gravel?

The standard worry is "gravel above the dig column will fall into the
robot's working cell and trap it". This does not happen in a
multi-cell `quarry` because layer 1 clears the entire `W × L`
rectangle including the chimney directly above the home column —
after one full layer pass, there is open sky above the dig area.
Gravel in adjacent walls does not fall sideways.

For a `1 × 1` shaft (degenerate case) the synchronous dig pattern
means each downward step is followed by a `swingUp` that breaks the
single gravel block that just landed on the robot's head, so a
gravel column is consumed at the same rate the robot descends.

The remaining real hazard is **cobblestone generation** when lava and
water meet in the chimney during the dig. That is what the
`retry_swing=true` on the return path is for.

### `tunnel` — straight 1×2 corridor

```
tunnel [-l LENGTH=32] [--torch K] [--no-deposit]
```

**Setup:** robot at the tunnel mouth facing along it. Slot 1 holds
torches if you pass `--torch`. Below the start tile: optional chest
for deposits.

Every step swings forward and up so a 1-wide, 2-tall corridor opens.
With `--torch K` the robot turns left, places a torch from slot 1
onto the side wall every `K` cells, and turns back. Auto-deposits at
home when the inventory fills (skip with `--no-deposit`).

### `stair` — descending 1-wide staircase

```
stair [-d DEPTH=32]
```

**Setup:** robot at the top of the slope facing into it.

Each step: swing forward, walk forward, swing down, descend, swing up
for head-room. The result is a regular 45° staircase you can walk
through. Does *not* return home — leave a torch trail and walk back
yourself.

### `fill` — place blocks across an area

```
fill [-w W=8] [-h H=8] [--up | --down] [--use]
```

**Setup:** robot at the corner of the area, facing the long edge.
Slot 1 holds the block to place (or the tool to use, e.g. a hoe).

Snakes the rectangle and runs `placeDown` (default), `placeUp`
(`--up`), or `useDown` (`--use`, e.g. tilling soil with a hoe). Use
this to set up a farm field in one pass: hoe with `--use`, then run
`farm` afterwards.

### `build` — blueprint builder

```
build <blueprint-file>
```

**Setup:** robot at the SW corner of where the structure should
appear, facing +x. Slots 1..16 hold the placement palette, where
slot N corresponds to letter `A + (N - 1)` in the blueprint.

Blueprint format (plain ASCII):

```
W L H
<W chars>            ← layer 1, row 1
<W chars>            ← layer 1, row 2
…
<W chars>            ← layer 1, row L
<blank line>
<W chars>            ← layer 2, row 1
…
```

Characters: `.` or space → empty cell, `A`..`P` → slot 1..16. The
robot processes layers bottom-up, walks each layer row-by-row, and
`placeDown`s the matching item. Suitable for small towers, fences,
walls, decorative shapes — not for anything that needs precise
rotation, since `place` on robots only orients to whatever face is
convenient.

### `sort` — chest-row sorter

```
sort --rules PATH [--passes N | --forever]
```

**Setup:** input chest below the start tile; output chests in a row
in front of the robot (chest at position N = cell `(N, 0)`). The
robot needs an `inventory_controller` upgrade so it can read item
names.

Rules file is a plain Lua return-table mapping item names to chest
indices, with optional `_default` catch-all:

```lua
return {
  ["minecraft:wheat"]       = 1,
  ["minecraft:wheat_seeds"] = 2,
  ["minecraft:carrot"]      = 3,
  ["minecraft:potato"]      = 3,
  _default                  = 4,
}
```

Items with no rule and no `_default` are returned to the input chest.

## Common pitfalls

### "The robot dug to bedrock and never came back."

Almost always one of:

1. **Energy exhaustion.** Charger above the start tile, or use
   `quarry`'s built-in reserve check (the `mine` script doesn't have
   it — `mine` is for shallow pits where 16 layers × 9 × 9 fits
   inside one battery).
2. **Cobble in the chimney.** Lava + water somewhere on the column
   above home tile. `nav:goto_y(0, true)` breaks through, but only on
   scripts that pass the flag — `quarry` and `mine` do, custom scripts
   need to as well.
3. **Inventory full mid-deep dig.** `quarry` handles this with
   `surface_and_dump`, but if you wrote a custom worker that ignores
   `inventory_full()` the robot will keep digging while drops vanish
   on the floor.

### "It harvests one row and then sits there."

Slot 1 ran out of seeds and the chest above is empty / wrong-keyed.
Pre-load slot 1 manually before the first run.

### "Even-width snake skipped the last column."

Not possible with this pack — `lib.robot.path.snake` enumerates
every cell exactly once for any `W × H`, and the selftest
`robot path snake covers W×H exactly once` enforces it on tricky
shapes (`4×4`, `4×5`, `5×4`, `2×7`). If you see this, you're using a
hand-rolled snake loop instead of the iterator.

### "It returned home but emptied items into a wall."

The robot navigated to `(0, 0)` but the chest underneath was missing
or broken. Robots can `dropDown` into thin air without raising an
error — the items just spawn on the floor. Check the chest is intact
before each work session, or add a `r.detectDown()` guard in your
custom script.

## Writing your own robot script

```lua
local args = ...
local nav_m  = require("lib.robot.nav")
local path_m = require("lib.robot.path")
local sched  = require("k.sched")

local nav = assert(nav_m.new())
local r = nav.r

for x, z in path_m.snake(9, 9) do
  nav:goto_xz(x - 1, z - 1, true)            -- 0-based; retry_swing=true
  pcall(r.swingDown)
  sched.sleep(0)                              -- yield to the scheduler
end
nav:home(true)                                 -- break through obstructions
```

Drop the file at `/bin/<name>.lua`, mark slot 1 with whatever your
script needs, and run.

Conventions to keep yourself out of trouble:

* **Always `sched.sleep(0)` once per cell** in long loops — the OC
  watchdog kills coroutines that yield-starve for >5 s real time.
* **Track inventory and energy on every cell**, not every layer. The
  cost of a check is one syscall; the cost of a stranded robot is a
  dig session.
* **Pass `retry_swing=true` to vertical and walk moves on the return
  path.** The dig site is always messier on the way out.
* **Call `nav:home(true)` at the end**, not a sequence of
  `nav:goto_y` / `nav:goto_xz` — `home` already does the right
  ordering (verticals first when going up, horizontals first when
  coming down).
