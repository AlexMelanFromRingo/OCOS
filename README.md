# OCOS — Open Computers Operation System

An independent, modern operating system for the [OpenComputers](https://github.com/MightyPirates/OpenComputers) Minecraft mod, written from scratch in Lua. Designed as a fresh alternative to MineOS and OpenOS, with a real process model, capability-based permissions, double-buffered GUI, and a proper package system.

## Status

Early development. Goals, architecture and milestones are in [`docs/DESIGN.md`](docs/DESIGN.md) and [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Repository layout

```
OCOS/
  src/         OCOS source code (kernel, libs, apps) — flashed to in-game disk
  reference/   Read-only clones of upstream projects (OC mod, MineOS, ocvm) — STUDY ONLY, never imported
  emulator/    Local ocvm instance directory with OCOS mounted as the boot filesystem
  tools/       Host-side dev tools (Python venv): static checker, packager, sync script
  docs/        Design, architecture and contributor docs
```

## Building / running locally

Prerequisites: `lua5.3`, `luarocks`, `python3` (>=3.10), a C++17 compiler. ocvm must be built once in `reference/ocvm/`.

```sh
# Static-check the Lua source tree
tools/lint.sh

# Sync src/ into the emulator instance and boot it
tools/run-emu.sh
```

## Why another OS

OpenOS is functional but minimal and shell-only. MineOS is feature-rich but has a single-event-loop architecture, no real process or permission model, dated infrastructure dependencies, and is no longer actively reliable. OCOS aims to:

- Give every app a real isolated process with declared capabilities.
- Render the GUI through a dirty-rectangle compositor and double buffer from day one.
- Ship a versioned, dependency-resolving package manager with offline cache.
- Provide first-class developer tools: editor with autocomplete, profiler, REPL, debugger.
- Stay neutral and portable: English-by-default, multi-locale, no hardcoded third-party servers.

## License

TBD by the project owner.
