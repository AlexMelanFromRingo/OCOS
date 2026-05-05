#!/usr/bin/env bash
# Push the current src/ tree directly into a Minecraft OC computer's
# saved filesystem. Faster than running the OCOS installer because we
# skip HTTP and the EEPROM flash — for iterating during development.
#
# Usage:
#   tools/sync-mc-disk.sh <path-to-OC-computer-fs>
#
# The path is the directory MC stores under
#   .minecraft/saves/<world>/opencomputers/<uuid>/
# i.e., the same one that has init.lua, sys/, bin/ etc. on it.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-}"

if [[ -z "$DEST" ]]; then
  cat <<EOF
usage: $0 <path-to-OC-computer-fs>

Default test path:
  /mnt/l/Games/Minecraft/MultiMC/instances/1.12.2/.minecraft/saves/OS/opencomputers/c750ac6b-d40e-46ec-abb8-d6f29314790c
EOF
  exit 2
fi

if [[ ! -d "$DEST" ]]; then
  echo "destination does not exist: $DEST" >&2
  exit 1
fi

# Wipe the existing OS but preserve user data.
echo "syncing src/ → $DEST"
rsync -a --delete \
  --exclude '/var/log/' \
  --exclude '/home/' \
  --exclude '.sh_history' \
  --exclude '/.ocos-symlinks' \
  --exclude '/etc/boot.selftest' \
  --exclude '/etc/boot.cfg' \
  "$ROOT/src/" "$DEST/"

echo "done. Reboot the OC machine in-game to pick up the new code."
echo "  Trace files (after reboot + world save):"
echo "    $DEST/var/log/init.trace"
echo "    $DEST/var/log/sessiond.trace"
echo "    $DEST/var/log/uid.trace"
