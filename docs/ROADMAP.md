# OCOS — Milestone Roadmap

Each milestone has an explicit **definition of done** (DoD) — something demonstrable in the ocvm emulator. Milestones are ordered by dependency. Inside a milestone, work proceeds in any order.

---

## M0 — Project setup ✅ done

- [x] Repo skeleton: `src/`, `tools/`, `docs/`, `reference/`, `emulator/`.
- [x] Reference clones: OpenComputers, MineOS, ocvm.
- [x] Local toolchain: `lua5.3`, `luarocks`, Python venv with `luaparser`, ocvm built.
- [x] Architecture documented in `docs/DESIGN.md`.

DoD: `tools/lint.sh` runs on an empty source tree without errors; ocvm boots an empty disk to a panic and we observe it.

---

## M1 — Bootable skeleton

Goal: OCOS boots in ocvm to an interactive shell. No GUI yet.

Tasks:
1. `efi/ocos.efi.lua` — the EEPROM image: GPU bind, locate boot FS, parse boot data, jump to `/init.lua`.
2. `tools/minify.py` — strip comments/whitespace/long names down to ≤4 KB.
3. `src/init.lua` — the 12-line shim that loads `/sys/boot.lua` via raw `component.invoke`.
4. `src/sys/boot.lua` — bootstrapper: sets `_OSVERSION`, monkey-patches `_G` minimally, loads kernel modules in order.
5. `src/sys/k/log.lua` — ring buffer + format helpers.
6. `src/sys/k/panic.lua` — top-level error handler with backtrace + halt screen.
7. `src/sys/k/signal.lua` — `pullSignal` pump, raw signal → IPC translation (stub IPC for now).
8. `src/sys/k/sched.lua` — scheduler (spawn, sleep, wait, run).
9. `src/sys/k/proc.lua` — process tables + sandboxed env.
10. `src/sys/k/vfs.lua` — VFS with mount table; auto-mount boot fs at `/` and tmpfs at `/tmp`.
11. `src/sys/drv/gpu.lua` + `src/sys/drv/screen.lua` + `src/sys/drv/kbd.lua` — minimal drivers good enough for tty.
12. `src/sys/std/io.lua` — buffered streams over the GPU/keyboard.
13. `src/sys/lib/term/console.lua` — VT100-ish terminal with cursor, scroll, line edit.
14. `src/bin/sh.lua` — micro-shell: tokenise, expand `$VAR`, run `/bin/<cmd>` Lua programs.
15. `src/bin/{ls,cat,echo,clear,reboot,shutdown,dmesg}.lua` — minimal command set.
16. `tests/k_sched_spec.lua`, `tests/k_vfs_spec.lua` — unit tests with stubbed `component`/`computer`.
17. `tools/sync.py` + `tools/run-emu.sh` — sync src/ to `emulator/instance/` and boot.

DoD: `tools/run-emu.sh` boots OCOS, the shell prompts, `ls /`, `dmesg`, `echo hi | cat`, `reboot` all work.

---

## M2 — Filesystem polish, services, packages-on-disk

Goal: services autoload, package-style installation works locally.

Tasks:
1. `sys/svc/logd.lua` — drains the log channel and rotates `/var/log/dmesg.log`.
2. `sys/svc/eventbus.lua` — subscription table for IPC.
3. `sys/svc/sessiond.lua` — session manager (login → shell or GUI).
4. Service framework: `/etc/services.cfg`, `bin/svc start|stop|status|enable`.
5. ACL layer in VFS: per-prefix `{owner, mode}`, kernel-side check on writes.
6. `sys/lib/pkg/` — install/uninstall from a local directory tree (no network).
7. `bin/pkg install <path>` — extract into `/apps` or `/sys/lib`, register in `/var/db/pkg/`.
8. SHA-256 verification on install (data card if present, pure-Lua fallback).
9. Property-based test for the scheduler (random schedules, no deadlock).

DoD: `pkg install ./hello` then `hello` runs the installed program; killing it from another shell via `kill <pid>` works.

---

## M3 — GUI compositor

Goal: a working window manager rendered through OC 1.7.5 buffer + bitblt.

Tasks:
1. `sys/drv/gpu.lua` — buffer allocation, dirty-rect tracking, frame flush.
2. `sys/lib/ui/compositor.lua` — composite tree, damage propagation, single bitblt to screen per frame.
3. `sys/lib/ui/widget.lua` — base widget with measure/layout/draw/on_event contract.
4. `sys/lib/ui/layout.lua` — flex/stack/grid layout helpers.
5. `sys/lib/ui/theme.lua` — theme loader + palette substitution.
6. `sys/lib/ui/widgets/{label,button,input,list,scrollbar,checkbox,window,menu}.lua`.
7. `sys/svc/themed.lua` — listens for `ui.theme.changed`, repaints.
8. `etc/themes/{default,dark,monochrome}.lua`.
9. `apps/desktop.app/` — first composite app: wallpaper + dock + clock.
10. Performance budget: idle desktop ≤ 1 GPU frame per 0.5 s, foreground app ≤ 1 frame per 0.1 s.

DoD: desktop boots; clicking the dock opens a placeholder app; theme switch repaints without flicker.

---

## M4 — Native apps

Goal: a useful built-in app set.

1. `apps/terminal.app/` — graphical terminal hosting `bin/sh.lua` over a pty.
2. `apps/files.app/` — file manager, drag/drop within OS, copy/move/delete.
3. `apps/settings.app/` — display, keyboard, theme, users, network.
4. `apps/edit.app/` — modal text editor (gap buffer, syntax HL via `sys/lib/codec/syntax.lua`, autocomplete from local symbol table built incrementally).
5. `apps/dmesg.app/` — live log viewer, filterable.
6. `apps/inspect.app/` — process tree, capability viewer, kill button.
7. `bin/edit` invokes `apps/edit.app/cli.lua` for headless editing.

DoD: file manager copies a file across filesystems with a progress bar; editor opens a 50 KB file and edits it; settings changes the theme live.

---

## M5 — Networking & remote registry

1. `sys/drv/modem.lua` + `sys/drv/internet.lua`.
2. `sys/lib/net/sock.lua` — async sockets backed by `internet_ready` signals.
3. `sys/lib/net/rpc.lua` — JSON-RPC over modem/internet, with per-channel auth.
4. `sys/lib/codec/json.lua` — strict JSON parser/printer (already needed for M2 manifests; here we add streaming).
5. `sys/svc/netd.lua` — DHCP-like address handshake, name resolution over modem.
6. Registry adapter: HTTP-served directory and Git-via-Smee fallback.
7. `bin/pkg install <id>` resolves through registries; `pkg search`.

DoD: `pkg install com.example.demo` from a registry hosted on GitHub Pages or a local HTTP server works end-to-end; signature verification rejects a tampered payload.

---

## M6 — Security & multi-user

1. PBKDF2 password hashing with per-user salt.
2. `sys/k/cap.lua` enforcement at every component access. Caps DB at `/etc/caps.db`.
3. App first-run consent dialog showing required caps; record grant.
4. Filesystem ACLs (M2 stub) get a UI in `apps/settings.app/`.
5. Audit log: any `cap.deny` event writes to `/var/log/audit.log`.
6. `sudo` — temporary cap elevation for admins.

DoD: a malicious app trying to delete `/sys/` is denied; the audit log shows the attempt; the admin can `sudo` to override after authentication.

---

## M7 — Developer experience

1. In-OS REPL with line history and autocompletion (`bin/repl`).
2. `sys/lib/devtools/profile.lua` — sampling profiler using `debug.sethook` (only outside scheduler).
3. `sys/lib/devtools/inspect.lua` — pretty-printer for nested tables, cycle-safe.
4. `apps/edit.app/` LSP-lite: project-wide symbol index, jump-to-definition, real-time errors via `tools/lint.py` integration over RPC.
5. `tools/pack.py` — produce `.ocpkg` (tar+manifest+signature) from a project directory.
6. `tools/lint.sh` integrated in CI.

DoD: editing an app inside OCOS, getting an autocomplete from a sibling library; `tools/pack.py` produces a verifiable `.ocpkg`; `pkg install ./that.ocpkg` lands and runs.

---

## M8 — Polish, dogfooding, docs

1. Localisation: full English + Ukrainian + 2 community-translated locales.
2. Wallpaper / icon pack v1.
3. Stress tests: 50 spawned processes, 1000 IPC msgs/sec, persistence round-trip.
4. Tutorials: "build your first app", "publish a package".
5. Site (GitHub Pages) with screenshots and `pkg` registry index.

---

## Ongoing parallel tracks

- **Compatibility (`compat-openos`)** — maintained alongside M2 onward; covered by a corpus test that runs OpenOS sample programs.
- **Performance** — every PR that touches `sys/k/sched.lua`, `sys/lib/ui/compositor.lua`, or `sys/drv/gpu.lua` runs the bench suite and must not regress > 5 %.
- **Security** — independent review pass at the end of M5 and M6.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| 5 s deadline kills our scheduler under load | Bench every kernel path; mandatory `sleep(0)` instrumentation in the linter |
| Eris persistence breaks our scheduler state | All scheduler state in plain tables; persistence smoke test in M2 |
| Off-screen buffer API differs across OC versions | Detect via `gpu.allocateBuffer` presence; fall back to direct draw on older OC with a degraded UI |
| Code growth → 5101-line `GUI.lua` syndrome | Lint rule: max 500 lines per file (warn), 800 (fail). One widget per file. |
| Russian-server lock-in pattern repeated | All endpoints from config files; default registry hosted on GitHub or self-hosted only |
