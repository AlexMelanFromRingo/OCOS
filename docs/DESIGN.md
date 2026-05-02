# OCOS — Architecture & Design

This document is the engineering contract for OCOS. It defines goals, the layered architecture, key interfaces, and the conventions every module must follow. Companion documents: [`ROADMAP.md`](ROADMAP.md) (milestone breakdown) and [`STYLE.md`](STYLE.md) (Lua coding rules — to be written).

## 1. Goals and non-goals

### Goals
1. A clean, modern Lua operating system for the OpenComputers mod (target: OC 1.7.5+, Lua 5.3 architecture, MC 1.12.2 / 1.16+ community ports).
2. Original codebase. We **study** OpenOS and MineOS but do not import or fork their code.
3. Real cooperative-multitasking model. Every running app is a supervised coroutine with its own environment, handles, and capability set.
4. Capability-based security: apps declare needed components and syscalls in a manifest; the kernel enforces.
5. Double-buffered, dirty-rectangle GUI rendered through OC 1.7.5+ off-screen buffers and a single `bitblt` flip. Theme-able, no hardcoded colors.
6. Decentralised, signed package distribution. Multiple registries; Ed25519 manifest signatures; offline cache.
7. First-class developer experience: editor with autocomplete, in-OS REPL, dmesg-style logger, profiler, debugger, host-side static checker.
8. Internationalisation with no hardcoded strings; English defaults; locale fallback.

### Non-goals
1. Backwards compatibility with OpenOS APIs at the source level. We will provide a **compatibility shim package** (`compat-openos`) so users can run OpenOS programs, but the native API is independent.
2. Compatibility with MineOS app bundles. (A converter may come later.)
3. Running on the Lua 5.2 architecture as the primary target. We support it best-effort via a build flag, but the Lua 5.3 CPU is canonical.
4. Replacing the EEPROM bootloader with custom Java/Scala code. We work entirely within the existing mod.

## 2. Hard constraints (platform)

These come from the OC mod itself and cannot be relaxed. See `memory/reference_oc_constraints.md` for source citations.

| Constraint | Value |
|---|---|
| Lua dialect | PUC-Rio Lua 5.3 native (with `goto`, `//`, bitwise, `string.pack`, `utf8`) |
| EEPROM size | 4096 B code + 256 B data |
| Yield deadline | 5.0 s real time without yielding → kill |
| Per-tick call budget | T1 0.5 / T2 1.0 / T3 1.5 |
| RAM tiers (KiB) | 192, 256, 384, 512, 768, 1024 (× 2 at runtime) |
| Max screen | T3: 160 × 50, 8-bit (240 fixed + 16 palette) |
| Max handles per computer | 16 default |
| Modem packet | 8192 B; max ports 16 |
| Internet TCP connections | 4 default |
| Signal queue depth | ~256, FIFO, drops oldest on overflow |
| Persistence | Eris-serialised; component proxies re-bind by address; closures over Java objects break |

Design corollaries:
- No preemption. Every long-running task **must** yield via `kernel.sleep(0)` (which calls `pullSignal(0)`).
- The kernel state must be plain data tables, not closure upvalues, to survive save/load.
- Component identity is the **address** string. Proxies are caches; rebuild on hotplug.
- The GUI **must** render to off-screen buffers and bitblt once per frame — direct `gpu.set` loops will burn the call budget.

## 3. Layered architecture

```
┌──────────────────────────────────────────────────────┐
│ Layer 7 — Apps (apps/<name>.app/)                    │
│   terminal, files, settings, editor, store, ...      │
├──────────────────────────────────────────────────────┤
│ Layer 6 — Frameworks (sys/lib/)                      │
│   ui, net, pkg, codec, lang, devtools, compat-openos │
├──────────────────────────────────────────────────────┤
│ Layer 5 — System services (sys/svc/)                 │
│   logd, eventbus, sessiond, pkgd, netd, themed       │
├──────────────────────────────────────────────────────┤
│ Layer 4 — Standard library (sys/std/)                │
│   string, table, io, os, json, lpeg-like, sched, ... │
├──────────────────────────────────────────────────────┤
│ Layer 3 — Drivers (sys/drv/)                         │
│   gpu, screen, kbd, fs, drive, modem, internet, ...  │
├──────────────────────────────────────────────────────┤
│ Layer 2 — Kernel (sys/k/)                            │
│   sched, proc, vfs, ipc, cap, log, panic, signal     │
├──────────────────────────────────────────────────────┤
│ Layer 1 — Boot (sys/boot.lua)                        │
│   loaded by /init.lua; brings up layers 2–4          │
├──────────────────────────────────────────────────────┤
│ Layer 0 — Firmware (efi/ocos.efi.lua → EEPROM)       │
│   tiny BIOS: chooses boot fs, jumps to /init.lua     │
└──────────────────────────────────────────────────────┘
```

The arrows always point upward — a higher layer can call any lower layer through its public interface, never via globals. Each layer owns its directory under `src/`.

## 4. Repository layout

```
OCOS/
  src/                     # Code that goes onto the in-game disk
    init.lua               # Loaded by EEPROM; calls boot
    sys/
      boot.lua             # Boot script: starts kernel, drivers, services
      k/                   # Kernel
        sched.lua          # Cooperative scheduler
        proc.lua           # Process abstraction
        vfs.lua            # Virtual filesystem with mount table
        ipc.lua            # Typed event channels
        cap.lua            # Capability enforcement
        log.lua            # Ring-buffer logger (dmesg-style)
        panic.lua          # Crash handler
        signal.lua         # Pulls signals, dispatches into IPC
      drv/                 # Drivers (one file per component type)
        gpu.lua            # Buffer-based GPU driver
        screen.lua         # Screen + multi-keyboard binding
        kbd.lua            # Keyboard event normaliser
        fs.lua             # Managed filesystem driver
        drive.lua          # Unmanaged block device
        modem.lua
        internet.lua
        redstone.lua
        data.lua           # Data card crypto
      std/                 # Stdlib extensions
        json.lua
        text.lua           # UTF-8 helpers
        io.lua             # Buffered streams
        sched.lua          # User-facing sleep/spawn
        bin.lua            # Binary string utilities
        match.lua          # Tiny LPEG-like parser combinators
      svc/                 # Long-running services
        logd.lua
        eventbus.lua
        sessiond.lua
        pkgd.lua
        netd.lua
        themed.lua
      lib/                 # User-facing frameworks
        ui/                # Compositor, widgets, layout
          compositor.lua
          widget.lua
          layout.lua
          theme.lua
          widgets/         # one file per widget
        net/               # High-level networking, RPC
        pkg/               # Package install / verify
        codec/             # OCIF image, OCBM bitmap, gzip-lite, etc.
        lang/              # Localisation
        devtools/          # REPL, profiler, inspect
        compat-openos/     # Optional shim for OpenOS programs
    bin/                   # CLI utilities
    apps/                  # GUI apps (each is .app/ dir)
    etc/                   # System config
      services.cfg
      keymap.cfg
      themes/
    home/                  # Default user dir template
  efi/
    ocos.efi.lua           # Source of the EEPROM image
    build.lua              # Minifier (host-side)
  tools/                   # Host-side dev tools (Python venv)
    lint.py                # luaparser-based checker
    pack.py                # Build .ocpkg packages
    sync.py                # Sync src/ to emulator
    minify.py              # EEPROM minifier
    run-emu.sh
    lint.sh
  docs/                    # Design, roadmap, contributor docs
  reference/               # Read-only upstream clones (NOT IMPORTED)
  emulator/                # ocvm instance + client.cfg
  tests/                   # Lua test suite (run with stub component/computer)
```

## 5. Key interfaces

### 5.1 Boot contract (with the mod)

The mod's `bios.lua` (in EEPROM) reads `/init.lua` from the boot filesystem, `load()`s it, and calls it. Our `efi/ocos.efi.lua` is built into a minified EEPROM image that:

1. Binds a GPU to a screen (so we can show panic messages).
2. Reads `eeprom.getData()`. If it parses as a `{fs=<addr>, kernel=<path>, mode=<safe|normal>}` table, use it; otherwise scan filesystems.
3. Locates `/init.lua` on the chosen FS.
4. If `mode=safe`, sets a global flag `_OCOS_SAFE = true` and skips `sys/svc/` autoloads later.
5. `load()` and call.

The minifier collapses to ≤4096 B; the boot config in 256 B has space for the canonical `{fs="<uuid>",kernel="/init.lua",mode="normal",retries=0}` and ~80 B of slack.

### 5.2 `/init.lua`

A tiny shim:

```lua
local addr, invoke = computer.getBootAddress(), component.invoke
local function readall(path)
  local h = assert(invoke(addr, "open", path))
  local b, c = "", nil
  repeat c = invoke(addr, "read", h, math.maxinteger or math.huge); b = b .. (c or "") until not c
  invoke(addr, "close", h); return b
end
local boot = assert(load(readall("/sys/boot.lua"), "=boot"))
return boot(readall)
```

That's the entire `/init.lua` — anything else lives under `/sys/`.

### 5.3 Kernel scheduler (`sys/k/sched.lua`)

The scheduler is the **only** place in the OS that calls `computer.pullSignal`. It owns the main coroutine. Its public API:

```lua
local sched = require("k.sched")

sched.spawn(fn, opts)        -- create a process; returns Process
sched.current()              -- current Process
sched.sleep(seconds)         -- yield until elapsed (uses pullSignal)
sched.wait(filter, timeout)  -- yield until matching event arrives
sched.exit(code)             -- terminate current process
sched.run()                  -- main loop (called once by boot)
```

`opts` carries: `name`, `caps` (capability set), `parent`, `env` (sandboxed `_ENV`), `priority` (`normal|low|high|realtime`), `restart_policy` (`one_shot|on_failure|always`).

A process is a plain table `{ id, name, status, coroutine, parent, children, caps, env, mailbox, exit_code, ... }`. State lives in this table only — no upvalue capture of live coroutines. This survives Eris.

The dispatch loop:

```
while not _OCOS_SHUTDOWN do
  -- 1. compute next deadline across all timers / sleeping procs
  -- 2. signal = computer.pullSignal(deadline_in)
  -- 3. enqueue signal in event bus
  -- 4. resume any process whose filter matches OR whose timer fired
  -- 5. realtime processes get one extra resume per loop turn
  -- 6. on uncaught error: log to dmesg, apply restart_policy, continue
end
```

Children of a crashed process inherit its `restart_policy` decision unless they have their own. The supervisor protects userland code from one app's crash freezing the whole system.

### 5.4 Capability model (`sys/k/cap.lua`)

A capability is a small token (string + optional argument) granting access to a system feature:

| Capability | Meaning |
|---|---|
| `component:gpu` | proxy/invoke any GPU |
| `component:filesystem:<addr>` | a specific filesystem |
| `component:filesystem:*` | any filesystem |
| `component:internet` | use an internet card |
| `component:modem:port:<n>` | open a specific modem port |
| `syscall:exec` | spawn a child process |
| `syscall:write:/etc/*` | write to /etc paths |
| `syscall:flash` | re-flash EEPROM |
| `ipc:channel:<name>` | publish or subscribe to an IPC channel |

Apps declare needed caps in their `manifest.cfg`. The user is shown a dialog on first run; the kernel records the grant in `/etc/caps.db`. `sched.spawn` constructs a sandboxed `_ENV` whose `component`, `computer`, `io.open` and `require` go through cap-checking wrappers.

### 5.5 VFS (`sys/k/vfs.lua`)

```lua
vfs.mount(proxy, mountpoint)
vfs.umount(mountpoint)
vfs.open(path, mode) → handle
vfs.list(path) → {names...}
vfs.exists(path), vfs.isdir(path), vfs.size(path), vfs.lastmod(path)
vfs.mkdir(path), vfs.remove(path), vfs.rename(old, new)
vfs.canonical(path) → '/abs/no/dotdot'
vfs.proxy_for(path) → component_proxy, sub_path
```

Mount table is a longest-prefix list. `/proc/<pid>/...` is a synthetic FS exposing process info as files. `/dev/<component_type>/<n>` exposes raw component proxies for diagnostics. The boot filesystem is mounted at `/`.

Path conventions:
- `/sys/` — kernel/services/lib, read-only by default after boot.
- `/etc/` — config.
- `/home/<user>/` — user home; `Application data/<App>/` for per-app state.
- `/mnt/<addr>/` — auto-mounted external filesystems.
- `/tmp/` — tmpfs (via `computer.tmpAddress()`).
- `/proc/`, `/dev/` — synthetic.
- `/var/log/` — rolled logs from `logd`.

### 5.6 IPC (`sys/k/ipc.lua`)

Typed channels:

```lua
ipc.publish(channel, payload)        -- payload is a serialisable table
ipc.subscribe(channel, handler)      -- handler(payload, meta)
ipc.unsubscribe(token)
ipc.request(channel, payload, timeout) -- RPC: returns reply or nil,err
ipc.serve(channel, handler)            -- handler returns the reply table
```

Channel names are hierarchical (`system.shutdown`, `ui.theme.changed`, `pkg.install.progress`). The kernel attaches `meta = {sender_pid, time}` to every delivery. Underneath, the eventbus service holds the subscription table and the kernel signal pump translates raw `pullSignal` events into a synthetic channel `oc.signal.<name>` so apps can subscribe to hardware events through the same API.

Events are objects, not 32 positional args.

### 5.7 GUI (`sys/lib/ui/`)

The compositor owns one off-screen GPU buffer per screen plus a "scratch" buffer for damaged regions:

```
draw cycle:
  for each window with dirty regions:
    intersect dirty rects with viewport
    redraw subtree(s) into the scratch buffer
    bitblt scratch → composite buffer at correct offset
  bitblt composite → screen
```

Widget contract:

```lua
local W = ui.widget.new("Button", {                -- type, defaults
  measure = function(self, max_w, max_h) return w, h end,
  layout  = function(self, x, y, w, h) ... end,
  draw    = function(self, ctx, dirty_rect) ... end,
  on_event= function(self, ev) return handled? end,
})
```

`ev` is a typed event object: `{type="touch", x=..., y=..., btn=..., player=...}` or `{type="key", code=..., char=..., down=true, mods={ctrl=true}}`. No positional unpacking ever.

Themes are tables loaded from `/etc/themes/<name>.lua`:

```lua
return {
  palette = { bg=0x1F1F1F, fg=0xE6E6E6, accent=0x4F8AF0, ... },
  button  = { bg=palette.bg, fg=palette.fg, hover_bg=..., padding={1,2,1,2}, ... },
  -- one entry per widget type
}
```

A widget gets `ctx.theme.button.bg` rather than `0x4F8AF0` literal.

### 5.8 Package system (`sys/lib/pkg/` + `sys/svc/pkgd.lua`)

A package is a directory with `manifest.cfg`:

```lua
return {
  id = "com.example.editor",
  name = "Editor",
  version = "1.4.0",
  authors = {"Alice <alice@example.com>"},
  license = "MIT",
  caps_required = {"component:gpu", "syscall:write:/home/*"},
  caps_optional = {"component:internet"},
  depends = { ["com.example.text-engine"] = ">=2.0,<3.0" },
  entry = "Main.lua",
  files = { ... },               -- with sha256 per file
  signature = "...",             -- Ed25519 over the canonical manifest
}
```

A registry is just a HTTP-served directory or a Git repo with `index.cfg` and per-package `manifest.cfg + payload.tar`. Multiple registries may be configured; signed manifests verify against trusted public keys.

### 5.9 Logging (`sys/k/log.lua`)

Ring buffer in RAM (default 256 entries × ≤256 B), persisted to `/var/log/dmesg.log` on rotate. Levels: `trace, debug, info, warn, error, fatal`. Every `log(level, tag, msg, kv)` is also pushed to IPC channel `log.<level>` so a UI viewer can subscribe live. `bin/dmesg` reads the buffer and tails the file.

## 6. Coding conventions

1. **English identifiers everywhere.** No Cyrillic in code or commits. User-facing strings live in localisation tables.
2. **Modules return a table.** No global side effects on `require`.
3. **No closure capture of live coroutines.** Keep state in plain tables that Eris can serialise.
4. **No hardcoded colors.** Always go through `theme`.
5. **No hardcoded URLs.** Network endpoints come from `/etc/registries.cfg` or app manifests.
6. **Errors carry context.** `error({code="EACCES", msg="...", path=...})` rather than bare strings, where the caller might catch them.
7. **`assert` is for invariants, not validation.** Validate at boundaries and return `nil, err`.
8. **One widget per file.** No 5000-line GUI library.
9. **One direction of dependency.** Lower layers must not require higher ones; circulars are caught by the linter.
10. **All code passes `tools/lint.sh` and the test suite before merge.**

## 7. Security posture

- EEPROM `makeReadonly` is **not** called by us. The user keeps the right to repair their machine.
- Apps run in a fresh `_ENV` with `component`, `computer`, `os.execute`-equivalents replaced by capability-checked wrappers. The raw globals are kept only in the kernel.
- Passwords use `pbkdf2(sha256, password, salt, iter)` with per-user salt. We pick `iter` per CPU tier so login takes ~250 ms (still 1000+ on T1).
- Network endpoints receive AEAD-encrypted payloads via `data card` AES when both ends have a tier-2 card, signed via Ed25519 (data card tier 3) when integrity matters. Plaintext is allowed for explicit `unsafe=true` connections.
- Filesystem ACLs are simple: for each path prefix, an entry `{owner, mode}` where mode is `rwx` for owner / `rx` for others. The kernel checks on `vfs.open(path, "w"|"a"|"r+")`.

## 8. Compatibility shim (`compat-openos`)

A best-effort `package.path` extension and a thin re-export that maps:

```
require("event")  → wrapper around ipc + sched.wait
require("term")   → wrapper around ui.console
require("filesystem") → wrapper around vfs
component, computer → cap-checked passthroughs
```

Programs that monkey-patch `coroutine` will not work — that's by design.

## 9. Out of scope (for now)

- Native graphics on tier-1 1-bit screens — we render text-only on T1.
- Booting from network (PXE-style) — possible later via the EEPROM extension.
- True real-time threads — OC has no preemption; "realtime" priority is just "first drained per scheduler turn".
