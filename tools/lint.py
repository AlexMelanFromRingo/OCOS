#!/usr/bin/env python3
"""Static syntax check for the OCOS Lua source tree.

Runs the `luaparser` library on every .lua file under src/, plus efi/.
Exit code 0 if everything parses; 1 if any file fails. Prints one line
per failure with file:line.
"""
from __future__ import annotations

import sys
from pathlib import Path

try:
    from luaparser import ast
except ModuleNotFoundError:
    print("luaparser is not installed; activate the venv first.", file=sys.stderr)
    sys.exit(2)


def lint_file(path: Path) -> str | None:
    try:
        src = path.read_text(encoding="utf-8")
    except OSError as e:
        return f"{path}: read error: {e}"
    try:
        ast.parse(src)
    except Exception as e:                        # luaparser raises antlr4 errors
        first = str(e).splitlines()[0] if str(e) else type(e).__name__
        return f"{path}: parse error: {first}"
    return None


def iter_lua(root: Path):
    for sub in ("src", "efi"):
        d = root / sub
        if not d.exists():
            continue
        for p in sorted(d.rglob("*.lua")):
            yield p


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    failures = []
    count = 0
    for path in iter_lua(root):
        count += 1
        msg = lint_file(path)
        if msg:
            failures.append(msg)
    print(f"lint: checked {count} files", file=sys.stderr)
    if failures:
        for f in failures:
            print(f)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
