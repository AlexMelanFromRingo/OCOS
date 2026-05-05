# Contributing to OCOS

This document is the short version. Read [`DESIGN.md`](DESIGN.md) and
[`ROADMAP.md`](ROADMAP.md) before opening a non-trivial PR.

## Style and conventions

1. **English identifiers everywhere.** No Cyrillic in code or commit
   messages. User-facing strings live in `/etc/locale/*.lua`.
2. **Modules return a table.** Side effects on `require` (other than
   defining the returned table) are forbidden.
3. **Keep state in plain tables.** Eris (the world-save serialiser) does
   not handle live coroutines, Java userdata, or closures over them. The
   scheduler, IPC, VFS — all keep state in tables that survive a save.
4. **No hardcoded colours.** Always go through `theme.palette.*` or a
   widget-specific theme key.
5. **No hardcoded URLs.** Network endpoints come from
   `/etc/registries.cfg` or app manifests.
6. **One widget per file** under `lib/ui/widgets/`. The widget contract
   is `measure / layout / draw / on_event`.
7. **No `M2 will fix this` placeholders.** Either implement now, or omit
   the API entirely. The stable surface should look the same on day one
   and day a hundred.
8. **All code passes `tools/lint.sh`** and the boot self-test
   (`tools/test-boot.sh`) before merge.

## Adding a new app

1. Create `src/apps/<id>.app/manifest.cfg` declaring `id`, `name`,
   `version`, `entry`, `caps_required`. See `src/apps/files.app/`.
2. Implement `Main.lua` — receives `(args, env, session)`. The session
   has `.compositor` (a live UI compositor) and `.notify(msg)`.
3. Add a launcher entry in `apps/desktop.app/Main.lua`.
4. Run `tools/test-boot.sh` to ensure the app loads under the stub
   compositor.

## Adding a service

1. Drop a unit file at `/etc/services/<id>.cfg` with `id`, `exec`,
   `caps`, `restart`, `autostart`, optional `after = {...}`.
2. Implement the service script under `/sys/svc/<id>.lua`. Subscribe to
   `svc.stop.<id>` for cooperative shutdown — `svc.manager` will
   `wait_pid` you up to 5 s before declaring you stuck.
3. The service inherits `null` streams by default; ask for explicit
   streams in your `exec.exec` if you need TTY access.

## Adding a locale

1. Copy `src/etc/locale/en.lua` to your code (e.g. `pl.lua` for Polish).
2. Translate every value. Do **not** rename keys — the framework relies
   on key stability for fallback to English on missing entries.
3. Set the locale by editing `src/etc/locale.cfg` to
   `return { default = "pl" }` and reboot, or call `lang.set("pl")`
   from a running shell.

## Adding a built-in command

1. Drop `src/bin/<name>.lua`. The chunk receives `(args, env)` and
   returns an integer exit code.
2. The shell's PATH lookup handles both `/<dir>/<name>.lua` and a bare
   `/<dir>/<name>` — pick `.lua` for consistency.
3. Update `src/bin/help.lua`'s section table.

## Reporting a bug

Boot the system with `tools/test-boot.sh`, paste its output, and include
the contents of `/var/log/dmesg.log` (and `/var/log/audit.log` if
relevant). The compositor's log viewer (`Logs` app from the dock) gives
the same data live.
