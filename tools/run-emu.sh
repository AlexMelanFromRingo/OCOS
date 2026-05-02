#!/usr/bin/env bash
# Launch OCOS in ocvm with the source tree as the boot filesystem.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OCVM="$ROOT/reference/ocvm/ocvm"
INSTANCE="$ROOT/emulator/instance"

if [[ ! -x "$OCVM" ]]; then
  echo "ocvm binary not found at $OCVM" >&2
  echo "build it with: (cd $ROOT/reference/ocvm && make lua=lua5.3)" >&2
  exit 1
fi

cd "$INSTANCE"
exec "$OCVM" "$INSTANCE" "$@"
