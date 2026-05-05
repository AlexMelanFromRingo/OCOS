#!/usr/bin/env bash
# Boot OCOS in each of the three modes (gui / console / safe) and
# verify init reached the expected stage. We pin the mode through a
# temporary /etc/boot.cfg in the boot fs (the in-disk menu honours
# that file ahead of the timed prompt), then read /var/log/init.trace
# from the writable /mnt/<addr>/ to see how far init got.
#
# This is a real boot — BIOS + kernel + drivers + init + svc.manager
# all run.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTANCE="$ROOT/emulator/instance"

# Move the selftest marker aside so init takes the normal autostart
# path, and restore it on exit.
cleanup() {
  rm -f "$ROOT/src/etc/boot.cfg"
  mv -f "$ROOT/src/etc/boot.selftest.bak" "$ROOT/src/etc/boot.selftest" 2>/dev/null || true
}
trap cleanup EXIT
mv -f "$ROOT/src/etc/boot.selftest" "$ROOT/src/etc/boot.selftest.bak"

wipe_writable() {
  for d in "$INSTANCE"/*/; do
    case "$(basename "$d")" in
      *-*-*-*-*) rm -rf "$d"/* ;;
    esac
  done
}

read_init_trace() {
  for d in "$INSTANCE"/*/var/log/init.trace; do
    [[ -f "$d" ]] && cat "$d" && return
  done
  echo ""
}

run_mode() {
  local mode="$1"
  local expect="$2"
  echo "----- mode=$mode -----"
  wipe_writable
  printf 'return { mode = "%s" }\n' "$mode" > "$ROOT/src/etc/boot.cfg"
  timeout 6 script -qc "$ROOT/tools/run-emu.sh" /tmp/ocvm-$mode.txt \
    </dev/null >/dev/null 2>&1 || true
  local trace
  trace=$(read_init_trace)
  if [[ -z "$trace" ]]; then
    echo "  FAIL ($mode): init.trace empty"
    tail -10 "$INSTANCE/log" 2>/dev/null
    return 1
  fi
  echo "$trace"
  if grep -qE "$expect" <<<"$trace"; then
    echo "  ok"
    return 0
  fi
  echo "  FAIL ($mode): trace did not match /$expect/"
  return 1
}

rc=0
run_mode safe    'boot mode: safe'    || rc=1
run_mode console 'started: logd, sessiond$' || rc=1
# GUI mode boots logd+sessiond first, then init.svc starts uid
# manually 300 ms later so uid's suspend lands on a sessiond already
# in wait_pid (mirrors a user typing `svc start uid` from the TTY).
run_mode gui     'uid started' || rc=1
exit $rc
