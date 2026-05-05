# OCOS — Open Computers Operation System

A modern, capability-secured Lua operating system for the
[OpenComputers](https://github.com/MightyPirates/OpenComputers) Minecraft
mod. Independent of OpenOS and MineOS in both code and infrastructure.

## What's in the box

- **Microkernel** with a real cooperative scheduler, supervised processes,
  capability sandbox, mountable VFS, IPC channels, and a structured
  ring-buffer logger that survives crashes via panic dumps.
- **Production shell** with pipes (`|`), redirects (`>`, `>>`, `<`, `2>`),
  conjunction (`&&`/`||`), sequence (`;`), POSIX-style quoting, variable
  expansion (`$VAR`, `${VAR}`, `$?`), aliases, and history.
- **Service framework** with declarative units (`/etc/services/<id>.cfg`),
  topo-sorted startup, supervised restart with exponential backoff, and a
  `svc` CLI. Built-in services: `logd`, `sessiond`, `uid`.
- **Package manager** with manifest-driven installs (id / version / sha256
  per file / semver dependencies / declared capabilities), a local DB at
  `/var/db/pkg/`, integrity verification (data-card SHA-256 with pure-Lua
  fallback), and an HTTP-based remote registry.
- **GUI compositor** rendering through a Lua-level virtual cell buffer
  with diff-based flush — same idea as MineOS' double-buffer, written
  fresh, exposed through a clean widget contract
  (`measure / layout / draw / on_event`). Themes, flex/stack/grid layout,
  ten widgets including a textarea with Lua syntax highlight and a
  pipe-backed terminal that hosts `/bin/sh.lua`.
- **Built-in apps** (`desktop`, `files`, `terminal`, `edit`, `dmesg`,
  `inspect`, `settings`).
- **Networking**: modem datagram sockets, JSON-RPC 2.0, internet card HTTP
  + TCP, registry resolution.
- **Security**: PBKDF2-HMAC-SHA256 password hashing with per-user salt,
  multi-user `/etc/passwd`, capability enforcement at `exec` and `vfs.open`
  boundaries, append-only audit log, `sudo` re-authentication.
- **Developer tools**: in-OS Lua REPL with multi-line input, cycle-safe
  inspect, wall-clock benchmark profiler, and a host-side packager
  (`tools/pack.py`) that produces signable `.ocpkg` directories.
- **Localisation**: English / Ukrainian / Russian / German shipped, easy
  to add more — flat key→string tables under `/etc/locale/<code>.lua`.

## Repository layout

```
OCOS/
  src/                     Code that goes onto the in-game disk
    init.lua               Loaded by the EEPROM BIOS
    sys/                   Kernel, drivers, stdlib, services, libraries
      boot.lua             Bootstrap: kernel modules, drivers, services
      k/                   Kernel: log, panic, signal, ipc, cap, vfs, proc, sched, exec
      drv/                 Drivers: gpu, screen, kbd, fs, modem, internet
      std/                 Stream / pipe / fstream / io / sha256 / pbkdf2 / json / semver / hmac
      svc/                 Long-running services: logd, sessiond, uid, init
      lib/                 Frameworks: term, ui (compositor + widgets), sh, net, pkg, auth, devtools, lang
    bin/                   CLI utilities + the shell
    apps/                  GUI app bundles (.app/manifest.cfg + Main.lua)
    etc/                   System config (services, themes, locales, security)
  efi/                     EEPROM image source
  tools/                   Host-side dev tools (Python venv): lint, run, test, pack
  docs/                    Design + roadmap
  reference/               Read-only upstream clones (NEVER imported)
  emulator/                ocvm instance with OCOS mounted as the boot fs
```

## Installing OCOS

See [`docs/INSTALL.md`](docs/INSTALL.md) for full instructions covering
real Minecraft, [Ocelot Desktop](https://gitlab.com/cc-ru/ocelot/ocelot-desktop)
emulator, ocvm, and manual loot-disk installs. The short version:

```sh
# Generate the self-contained installer (writes dist/ocos-installer.lua):
tools/build-installer.py

# On the target VM running OpenOS, with the installer reachable via HTTP:
wget https://example/ocos-installer.lua /tmp/ocos.lua && /tmp/ocos.lua
```

## Build & run locally

Prerequisites: `lua5.3`, `luarocks`, Python ≥3.10, a C++17 compiler. Build
the [ocvm](https://github.com/payonel/ocvm) emulator once:

```sh
(cd reference/ocvm && make lua=lua5.3)
```

Then:

```sh
tools/lint.sh         # static check the Lua source
tools/test-boot.sh    # boot OCOS in self-test mode and report
tools/run-emu.sh      # boot OCOS interactively
tools/pack.py <dir> -o <out>   # build a .ocpkg from a project directory
```

The boot self-test currently exercises 28 checks: kernel scheduling,
IPC, VFS, the GPU driver, the shell pipeline / redirect / control flow,
service framework, package install + tamper detection, JSON, PBKDF2 +
user CRUD, capability enforcement, the UI buffer / theme / widget /
layout, all built-in apps' setup paths, and 50-process / 1000-message
stress.

## Why another OS

OpenOS is functional but minimal and shell-only. MineOS is feature-rich
but has a single-event-loop architecture (no real coroutine model), no
permission model, hardcoded dependencies on third-party servers, and is
no longer reliably maintained. OCOS is independent in both code and
infrastructure: every endpoint comes from `/etc/registries.cfg`, every
component is capability-gated, and every layer has a small public API
that's easy to test in isolation.

## License

TBD.
