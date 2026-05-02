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

# `script` gives ocvm a real PTY (avoids 0×0 gpu); the OS shuts down on
# completion so the outer timeout is just a stuck-boot guard.
timeout 10 script -qc "$ROOT/tools/run-emu.sh" /tmp/ocvm-selftest.txt </dev/null >/dev/null 2>&1 || true

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
