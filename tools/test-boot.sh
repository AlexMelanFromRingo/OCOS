#!/usr/bin/env bash
# Boots OCOS in self-test mode: the kernel runs short checks, writes
# /selftest.log onto the writable filesystem, and shuts down. We dump the
# result to stdout. Returns 0 if all checks pass, 2 on any FAIL,
# 1 if the boot did not even produce a result file.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTANCE="$ROOT/emulator/instance"

# Wipe every uuid-shaped subdir so we can detect a missing log.
for d in "$INSTANCE"/*/; do
  d="${d%/}"
  base="$(basename "$d")"
  case "$base" in
    *-*-*-*-*) rm -rf "$d"/* ;;
  esac
done

# Stage the ocos.robot package into the writable FS so the selftest
# can exercise `install.install_dir` against a real package directory
# (not a synthetic one). The 88895671-... UUID is the writable
# "ocos-data" filesystem in emulator/instance/client.cfg.
WRITABLE_FS="$INSTANCE/88895671-49ba-f22d-bef9-1db9a5438b71"
PKG_STAGE_SRC="$ROOT/dist/registry/ocos.robot/0.1.1"
if [[ -d "$PKG_STAGE_SRC" && -d "$WRITABLE_FS" ]]; then
  mkdir -p "$WRITABLE_FS/pkg-stage/ocos.robot"
  cp -r "$PKG_STAGE_SRC/." "$WRITABLE_FS/pkg-stage/ocos.robot/"
fi

# `script` gives ocvm a real PTY (avoids 0×0 gpu); the OS shuts down on
# completion so the outer timeout is just a stuck-boot guard.
# 180s budget — RSA verify on 1024-bit takes ~10-30s of pure-Lua
# mod-mul on modest hardware, and the watchdog yields it down further.
# 240s — RSA verify on 1024-bit takes ~10-30 s of pure-Lua mod-mul on
# the simulated T1 ocvm CPU; the watchdog yields it down further.
timeout 240 script -qc "$ROOT/tools/run-emu.sh" /tmp/ocvm-selftest.txt </dev/null >/dev/null 2>&1 || true

LOG="$(find "$INSTANCE" -mindepth 2 -maxdepth 2 -name selftest.log -print -quit || true)"
if [[ -z "$LOG" || ! -f "$LOG" ]]; then
  echo "selftest.log not written — boot likely stalled before self-test" >&2
  echo "--- ocvm log tail ---" >&2
  tail -30 "$INSTANCE/log" >&2 || true
  exit 1
fi

cat "$LOG"
if grep -q "^FAIL " "$LOG"; then
  exit 2
fi
