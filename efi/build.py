#!/usr/bin/env python3
"""Pack efi/ocos.efi.lua into an EEPROM-sized image.

Strips comments, blank lines and squeezes runs of whitespace; verifies the
result still parses as Lua by handing it to luaparser, and that it fits in
the OC EEPROM code budget (4096 B).

Usage: efi/build.py [--out efi/ocos.efi.min.lua]
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

try:
    from luaparser import ast as lua_ast
except ModuleNotFoundError:                       # pragma: no cover
    lua_ast = None

EEPROM_CODE_LIMIT = 4096


def strip_lua(src: str) -> str:
    out = []
    i, n = 0, len(src)
    in_str = None                                  # None | "'" | '"' | '[='
    while i < n:
        c = src[i]
        if in_str:
            out.append(c)
            if in_str in ("'", '"'):
                if c == "\\" and i + 1 < n:
                    out.append(src[i + 1]); i += 2; continue
                if c == in_str: in_str = None
            else:                                  # long bracket
                if src.startswith(in_str, i):
                    out.extend(in_str[1:]); i += len(in_str); in_str = None; continue
            i += 1; continue
        if c in "\"'":
            in_str = c; out.append(c); i += 1; continue
        if c == "[":
            m = re.match(r"\[=*\[", src[i:])
            if m:
                token = m.group(0)
                in_str = "]" + "=" * (len(token) - 2) + "]"
                out.append(token); i += len(token); continue
        if c == "-" and src.startswith("--", i):
            # comment: long form?
            j = i + 2
            m = re.match(r"\[=*\[", src[j:])
            if m:
                close = "]" + "=" * (len(m.group(0)) - 2) + "]"
                end = src.find(close, j + len(m.group(0)))
                i = (end + len(close)) if end != -1 else n
                continue
            # short comment until newline
            nl = src.find("\n", j)
            i = nl if nl != -1 else n
            continue
        out.append(c); i += 1
    text = "".join(out)
    # Collapse runs of whitespace, drop blank lines.
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r" *\n+ *", "\n", text)
    return text.strip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--src", default=str(Path(__file__).with_name("ocos.efi.lua")))
    parser.add_argument("--out", default=str(Path(__file__).with_name("ocos.efi.min.lua")))
    args = parser.parse_args()

    src_path = Path(args.src)
    out_path = Path(args.out)
    src = src_path.read_text(encoding="utf-8")
    minified = strip_lua(src)

    if lua_ast is not None:
        try:
            lua_ast.parse(minified)
        except Exception as e:                    # pragma: no cover - lint failure
            print(f"minified output failed to parse: {e}", flush=True)
            return 2

    out_path.write_text(minified, encoding="utf-8")
    size = len(minified.encode("utf-8"))
    headroom = EEPROM_CODE_LIMIT - size
    print(f"{out_path}: {size} B  ({headroom:+d} B vs 4096 B EEPROM limit)")
    if size > EEPROM_CODE_LIMIT:
        print("ERROR: exceeds the EEPROM code limit", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
