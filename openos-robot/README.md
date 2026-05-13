# openos-robot — robot scripts for stock OpenOS

A standalone port of the nine OCOS robot scripts (farm, quarry, mine,
tunnel, stair, tree, fill, build, sort) plus the `nav`/`path`
libraries they sit on. Designed to live on a floppy and be installed
onto any robot running stock OpenOS — no OCOS install required.

**This folder is intentionally self-contained.** It is *not* part of
the OCOS package set, doesn't get installed when you `pkg install
ocos.robot`, and shares no code at runtime with the rest of the repo.
The OCOS originals under `pkg-src/ocos.robot/` are untouched.

## Why a separate floppy

OCOS is a full Lua OS with a scheduler, VFS, IPC, package manager and
GUI compositor. That's plenty of disk + RAM that a robot doesn't have
to spare. On a Tier 1 robot you get one EEPROM, one hard drive, and
not much else — running OpenOS leaves enough headroom for these
scripts and nothing more is needed. So: instead of porting OCOS to fit
on a robot, we port the *scripts* to fit on OpenOS.

## File layout

```
openos-robot/
  README.md
  install.lua           ← run this once after mounting the floppy
  lib/
    nav.lua             ← coordinate-tracking navigation
    path.lua            ← snake / rows / spiral iterators
  bin/
    farm.lua tree.lua mine.lua quarry.lua tunnel.lua
    stair.lua fill.lua build.lua sort.lua
```

## How to put this on a robot

1. **Make a floppy.** Insert a blank floppy disk into a disk drive
   attached to any computer (player workstation, charger, whatever).
   On OpenOS:

   ```sh
   df                           # find the floppy's mount point
   cp -r /home/openos-robot/* /mnt/<floppy-addr>/
   ```

   …where `/home/openos-robot/` is wherever you `wget`'d this tree to.
   Alternatively grab everything in one shot via OCOS's git tool from
   any machine that has it:

   ```sh
   git clone https://github.com/AlexMelanFromRingo/OCOS /tmp/OCOS
   cp -r /tmp/OCOS/openos-robot/* /mnt/<floppy-addr>/
   ```

   If you have an internet card on the workstation and don't want to
   clone the whole repo, the raw URLs work too:

   ```sh
   for f in install.lua lib/nav.lua lib/path.lua \
            bin/farm.lua bin/tree.lua bin/mine.lua bin/quarry.lua \
            bin/tunnel.lua bin/stair.lua bin/fill.lua bin/build.lua \
            bin/sort.lua; do
     mkdir -p /mnt/<floppy-addr>/$(dirname $f)
     wget -q -f https://raw.githubusercontent.com/AlexMelanFromRingo/OCOS/main/openos-robot/$f \
              /mnt/<floppy-addr>/$f
   done
   ```

2. **Insert the floppy in the robot.** Robot's disk drive picks it up;
   OpenOS auto-mounts it under `/mnt/<addr>/`.

3. **Install.** On the robot:

   ```sh
   /mnt/<addr>/install.lua
   ```

   That copies `lib/*` → `/home/lib/` and `bin/*` → `/home/bin/`,
   which OpenOS already includes in its default `LUA_PATH` / `PATH`.
   After this the commands `farm`, `quarry`, `mine`, `tunnel`,
   `stair`, `tree`, `fill`, `build`, and `sort` are on the shell.

4. **Eject the floppy** (optional). Everything is on the robot's hard
   drive now. The floppy can go back into your workstation for the
   next robot.

## Quick reference

Each script has a comment header documenting its setup and flags;
the highlights:

```
farm    [-w W=9] [-h H=9] [--passes N | --forever]
            Wheat/carrot/potato farmer. Chest BELOW = harvest,
            chest ABOVE = seed reserve. Slot 1 must hold at least
            one seed at startup.

tree    [-n COUNT=4] [-s SPACING=4] [--passes N | --forever]
            Sapling-row lumberjack. Robot HOVERS one tile above the
            dirt row. Chest below the start tile, slot 1 has saplings.

mine    [-w W=9] [-l L=9] [-d D=16]
            Strip-miner. Surfaces after every layer. Chest below.
            For D > 16 use `quarry` (smarter energy + cobble handling).

quarry  [-w W=9] [-l L=9] [-d D=64]
            Deep 3D quarry. Stays underground; surfaces only when
            inventory full or distance_home × move_cost + reserve
            exceeds remaining energy. Waits on charger if low.

tunnel  [-l LENGTH=32] [--torch K] [--no-deposit]
            1×2 corridor. Optional torch on left wall every K cells.

stair   [-d DEPTH=32]
            Descending 1-wide staircase at 45°.

fill    [-w W=8] [-h H=8] [--up | --down] [--use]
            Snake-fill a W×H area below (or above with --up).
            `--use` activates slot 1 (e.g. hoe → till dirt).

build   <blueprint-file>
            Place blocks per a plain-ASCII blueprint:
              "W L H" header, then H layers of L rows of W chars.
              '.'/space = empty, A..P = slot 1..16.

sort    --rules <path> [--passes N | --forever]
            Chest-row sorter. Input chest below, output chests in a
            row forward. `--rules` file is plain Lua returning a
            { ["minecraft:wheat"] = 1, ..., _default = N } table.
            Requires the inventory_controller upgrade.
```

## Architecture (one minute)

* **`nav.lua`** wraps OpenOS's `robot` library with absolute-coordinate
  tracking. `nav:goto_xz(x, z)`, `nav:goto_y(y, retry_swing)`,
  `nav:home(retry_swing)`. With `retry_swing=true` the robot breaks
  blocks above/below to get through cobble that forms on the return
  path during a long dig. `nav:distance_home()` returns the Manhattan
  distance for energy planning.
* **`path.lua`** yields cells `(x, z)` for the three traversal shapes
  (snake / rows / spiral). The iterator is the source of truth — the
  classic "even-width snake doesn't return to origin" bug can't happen
  because the robot never counts steps; it just visits whatever cells
  the iterator hands it and then calls `nav:home()`.

## OpenOS APIs we depend on

The port stays inside the standard OpenOS surface:

* `require("robot")` — high-level robot lib (forward, swingUp, …)
* `require("computer")` — `energy()` / `maxEnergy()`
* `require("component")` — used directly only by `sort` to talk to
  `inventory_controller` for reading item names
* `require("filesystem")`, `require("shell")`, `require("process")` —
  only by the installer
* `os.sleep(seconds)` — cooperative yield (works with 0)
* `io.open` / `io.write` / `io.stderr` — file + console I/O

That's it. No internet card, no GPU, no third-party libs.

## What about OCOS

The same scripts live under `pkg-src/ocos.robot/bin/` in this repo and
ship as a registry package for OCOS itself. The OCOS versions use
OCOS's `lib.robot.nav`/`lib.robot.path` and the kernel scheduler
(`sched.sleep`). They are kept in sync feature-wise but the two trees
are intentionally separate so the OpenOS port doesn't drag in any of
OCOS's runtime — and so changes to OCOS internals never break the
floppy scripts.
