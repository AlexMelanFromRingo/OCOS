# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

OCOS is an original, capability-secured Lua operating system for the OpenComputers Minecraft mod. It is **not** a fork of OpenOS or MineOS — those live read-only under `reference/` for study and must never be imported. The Lua source under `src/` is what gets written to an in-game disk; everything under `tools/` and `efi/` is host-side build/dev infrastructure.

Target platform: OpenComputers 1.7.5+, Lua 5.3 architecture. Read `docs/DESIGN.md` (engineering contract) before non-trivial changes; `docs/ROADMAP.md` for milestone scope; `docs/STYLE.md` for Lua conventions.

## Common commands

All scripts assume the repo root is the working directory.

```sh
# One-time: build the ocvm emulator OCOS uses for CI / interactive boot.
(cd reference/ocvm && make lua=lua5.3)

tools/lint.sh                 # luaparser-based syntax check across src/ and efi/
tools/test-boot.sh            # boot OCOS in self-test mode (28 checks); 0=pass, 2=any FAIL, 1=stalled boot
tools/run-emu.sh              # interactive boot of OCOS in ocvm using src/ as the boot fs
tools/pack.py <dir> -o <out>  # build a .ocpkg from a project dir (computes per-file sha256)
tools/build-installer.py      # regenerate dist/ocos-installer.lua + dist/install-manifest.lua after editing src/
```

There is currently no Lua unit-test harness (`tests/` is empty). The boot self-test driven by `tools/test-boot.sh` is the canonical correctness signal — it reads/writes `/selftest.log` on the emulator's writable disk. Tests live inside the OS at `src/etc/boot.selftest/` and are excluded from the production install manifest.

The Python venv at `.venv/` provides `luaparser`. `tools/lint.sh` is a thin wrapper that exec's `.venv/bin/python tools/lint.py`.

## Boot path (read once, then `git log src/sys/boot.lua` for changes)

1. Stock OpenComputers EEPROM finds `/init.lua` on the boot filesystem.
2. `src/init.lua` (12 lines, runs before VFS exists) reads `/sys/boot.lua` via raw `component.invoke` and calls it with `(boot_addr, read_all)`.
3. `src/sys/boot.lua` builds a minimal `require` rooted at `/sys/`, then brings up kernel modules **in this exact order**: `k.log`, `k.panic`, `k.signal`, `k.ipc`, `k.cap` (with `enforce=false` initially), `k.vfs`, `k.proc`, `k.sched`. After `vfs.init` it re-reads `/etc/security.cfg` to flip cap enforcement.
4. Drivers register: `drv.gpu`, `drv.screen`, `drv.kbd`, `drv.fs`. Then it replays `component.list()` as `oc.signal.component_added` IPC events so drivers discover already-attached hardware.
5. `sched.spawn(svc.init.main, …)` starts the init service (which reads `/etc/services/*.cfg` and topo-sorts startup); `sched.run()` enters the main loop and never returns.

Hard rules from this boot contract:
- The scheduler is the **only** caller of `computer.pullSignal`. User code uses `sched.wait`, `sched.sleep`, `sched.wait_pid`. Never `coroutine.yield` directly.
- Kernel and process state live in plain tables — never closure-captured live coroutines — because Eris (the world-save serialiser) cannot persist coroutines or Java userdata.
- Every module is `require`'d via the boot's loader and must `return` a table; side effects on require are forbidden.

## Architecture in layers

`src/sys/` enforces a strict bottom-up dependency direction. Higher layers may call lower; never the reverse.

| Path | Layer | Notes |
|---|---|---|
| `src/sys/k/` | Kernel | `log`, `panic`, `signal`, `ipc`, `cap`, `vfs`, `proc`, `sched`, `exec` |
| `src/sys/drv/` | Drivers | one file per OC component type (`gpu`, `screen`, `kbd`, `fs`, `modem`, `internet`) |
| `src/sys/std/` | Stdlib | streams, pipes, fstream, io |
| `src/sys/lib/codec/` | Codecs | `sha256`, `pbkdf2`, `hmac`, `json`, `semver` (depended on by lib/auth, lib/pkg) |
| `src/sys/lib/sh/` | Shell engine | `lexer` → `parser` → `runner`; `builtins` defines `cd`, etc. `bin/sh.lua` is just the entry. |
| `src/sys/lib/term/` | TTY | `console`, `tty`, `keymap` — the line editor for the shell |
| `src/sys/lib/ui/` | GUI compositor | `buffer` (virtual cell buffer with diff flush), `compositor`, `widget`, `layout`, `theme`, `event`, `widgets/*` |
| `src/sys/lib/pkg/` | Package mgr | `manifest`, `db`, `install`, `registry` |
| `src/sys/lib/auth/` | Auth | `users`, `audit` (PBKDF2 hashes, append-only audit log) |
| `src/sys/lib/net/` | Networking | `sock` (modem datagrams + internet-card TCP/HTTP), `rpc` (JSON-RPC 2.0) |
| `src/sys/lib/devtools/` | Dev | REPL, cycle-safe `inspect`, `profile` |
| `src/sys/lib/lang.lua` | i18n | flat key→string tables under `etc/locale/<code>.lua`; English is the fallback |
| `src/sys/svc/` | Services | `init` (reads units, topo-sorts), `logd`, `sessiond`, `uid` (compositor + desktop) |
| `src/bin/` | CLI utilities | each is a `(args, env) → exit_code` chunk; help.lua's section table must be updated when adding one |
| `src/apps/<id>.app/` | GUI apps | `manifest.cfg` + `Main.lua(args, env, session)` where `session` carries `.compositor` and `.notify` |

The shell pipeline (`|`, `>`, `>>`, `<`, `2>`, `&&`/`||`, `;`, `$VAR`/`${VAR}`/`$?`, aliases, history) is implemented in `src/sys/lib/sh/`, not in `bin/sh.lua`. Quoting is POSIX-style.

The compositor model is "Lua-level virtual cell buffer with diff-based flush" — same idea as MineOS' double-buffer but rewritten. Widgets implement the `measure / layout / draw / on_event` contract; one widget per file under `lib/ui/widgets/`. `event` objects are typed (`{type="touch", …}` / `{type="key", …}`), never positional unpacks.

Services: drop `/etc/services/<id>.cfg` with `id`, `exec`, `caps`, `restart`, `autostart`, optional `after = {...}`. Implement at `/sys/svc/<id>.lua`. Subscribe to IPC `svc.stop.<id>` for cooperative shutdown — `svc.manager` waits up to 5 s before declaring the service stuck. Services inherit `null` streams unless they ask for a TTY in their `exec.exec` call. The `uid` service is `autostart=false` because headless ocvm reports a 0×0 GPU — start it manually with `svc start uid` on a real machine.

Capabilities (`k.cap`) are string tokens like `component:gpu`, `component:filesystem:<addr>`, `syscall:exec`, `ipc:channel:<name>`. Apps declare `caps_required` in their manifest. Enforcement is **off by default** (`/etc/security.cfg`) so a fresh disk boots into a root shell. Flip `enforce=true` after creating users.

## Hard platform constraints (don't break these)

These come from the OC mod itself. See `docs/DESIGN.md §2` for the source citations.

- Lua 5.3 PUC-Rio, with `goto`, `//`, bitwise, `string.pack`, `utf8`. EEPROM ≤ 4096 B code + 256 B data.
- 5 s real-time yield deadline → kernel kills the coroutine. CPU-bound work must `sched.sleep(0)` at least once a second.
- Per-tick GPU/syscall budget (T1 0.5 / T2 1.0 / T3 1.5). Never `gpu.set` in a tight loop on user input — render through `lib/ui/buffer` and let the compositor diff-flush.
- T3 max screen 160×50, 8-bit colour (240 fixed + 16 palette). Component identity is the **address string** — proxies are caches, rebuild on hotplug.
- Eris persistence: closures capturing live coroutines or Java userdata break. Keep state in plain tables.

## Conventions enforced before merge

(Mirrored from `docs/CONTRIBUTING.md` and `docs/STYLE.md`.)

1. **English identifiers everywhere** — no Cyrillic in code or commit messages. User-facing strings live in `etc/locale/*.lua` only.
2. **Every module returns a table.** No global side effects on `require`.
3. **No closure capture of live coroutines.** State in plain tables for Eris persistence.
4. **No hardcoded colours** — go through `theme.palette.*` or a widget-specific theme key.
5. **No hardcoded URLs** — endpoints come from `/etc/registries.cfg` or app manifests.
6. **One widget per file** under `lib/ui/widgets/`. Widget contract is `measure / layout / draw / on_event`.
7. **No "M2 will fix this" placeholders.** Implement the surface or omit it; committed code must be production quality.
8. **One direction of dependency.** Lower layers must not require higher ones.
9. **`assert` is for invariants only.** Validate at boundaries and return `nil, err`. `error()` is reserved for unrecoverable kernel/sandbox cases.
10. `tools/lint.sh` and `tools/test-boot.sh` must pass before merge.

When adding a CLI command: drop `src/bin/<name>.lua` returning an integer exit code, and update `src/bin/help.lua`'s section table. When adding an app: `src/apps/<id>.app/manifest.cfg` (`id`/`name`/`version`/`entry`/`caps_required`) plus `Main.lua`, then add a launcher entry in `apps/desktop.app/Main.lua`. When adding a locale: copy `src/etc/locale/en.lua` and translate values without renaming keys (English is the fallback).

## Reference clones — read-only

`reference/` (gitignored) holds local clones of OpenComputers, MineOS, and ocvm. **Never import or copy code from these into `src/`.** They exist for reading APIs and studying behaviour. The ocvm binary built there is the emulator used by `tools/run-emu.sh` and `tools/test-boot.sh`.

## Installer and on-disk layout

`tools/build-installer.py` regenerates `dist/ocos-installer.lua` (the streaming bootstrap that runs on OpenOS) and `dist/install-manifest.lua` (every file with size + sha256). Per-file streaming with size-verify is intentional — single-chunk writes interleaved silently in real OC 1.7.10. `--local <prefix>` lets the same installer read from a host-mounted loot disk instead of HTTP. The production manifest excludes `etc/boot.selftest/`.

## Testing UI / GUI changes

ocvm reports `0×0` for the GPU when stdout is not a real TTY, so `tools/run-emu.sh` will not show the desktop in a normal CI shell. `tools/test-boot.sh` works around this with `script -qc …` to allocate a PTY, but it only exercises kernel paths (no rendering). For visual verification, run inside Ocelot Desktop or real Minecraft per `docs/INSTALL.md`. If you can't visually verify, say so — don't claim a UI change works because the self-test passed.
