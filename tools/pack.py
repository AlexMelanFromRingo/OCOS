#!/usr/bin/env python3
"""Build a .ocpkg from a project directory.

A .ocpkg is a directory tree containing manifest.cfg and the declared
files. This script:

  1. Reads the source manifest (id, name, version, depends, caps_*).
  2. Walks the source tree honouring an `include` glob list.
  3. Computes SHA-256 of each included file.
  4. Emits an output-directory copy with a complete manifest.cfg whose
     `files` table has one entry per file with the computed sha256.

The output directory can then be installed via `pkg install <dir>` on
the OCOS side, or served from a registry.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import shutil
import sys
from pathlib import Path

LUA_TEMPLATE = """return {{
  id          = {id!r},
  name        = {name!r},
  version     = {version!r},
  description = {description!r},
  authors     = {{ {authors} }},
  license     = {license!r},
  prefix      = {prefix!r},
  depends     = {{ {depends} }},
  caps_required = {{ {caps_required} }},
  caps_optional = {{ {caps_optional} }},
  files       = {{
{files}
  }},
  entry       = {entry!r},
{extra}}}
"""


def lua_str(s: str) -> str:
    if s is None:
        return "nil"
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_array(values: list[str]) -> str:
    return ", ".join(lua_str(v) for v in values)


def lua_table_pairs(t: dict[str, str]) -> str:
    return ", ".join(f"[{lua_str(k)}] = {lua_str(v)}" for k, v in t.items())


def read_manifest(src_manifest: Path) -> dict:
    """Quick-and-dirty Lua-table parser for manifest fields we care about.

    The manifest must be a plain `return { ... }` chunk with literal values
    only; this avoids dragging a Lua interpreter into the host build.
    """
    text = src_manifest.read_text(encoding="utf-8")
    # Strip comments (line + block).
    out = []
    i = 0
    while i < len(text):
        if text.startswith("--", i):
            nl = text.find("\n", i)
            i = nl if nl != -1 else len(text)
        else:
            out.append(text[i])
            i += 1
    body = "".join(out)
    # Extract top-level fields by simple regex per name. Good enough for the
    # constrained schema used by OCOS package manifests.
    import re
    def grab_str(name):
        m = re.search(rf"{name}\s*=\s*\"([^\"]*)\"", body)
        return m.group(1) if m else ""
    def grab_array(name):
        m = re.search(rf"{name}\s*=\s*\{{([^}}]*)\}}", body)
        if not m: return []
        return [s.strip().strip('"') for s in m.group(1).split(",") if s.strip()]
    def grab_pairs(name):
        m = re.search(rf"{name}\s*=\s*\{{([^}}]*)\}}", body, re.DOTALL)
        if not m: return {}
        out = {}
        for entry in re.finditer(r'\["?([^"\]]+)"?\]\s*=\s*"([^"]*)"', m.group(1)):
            out[entry.group(1)] = entry.group(2)
        return out
    def grab_int(name):
        m = re.search(rf"{name}\s*=\s*(-?\d+)", body)
        return int(m.group(1)) if m else None
    def grab_bool(name):
        m = re.search(rf"{name}\s*=\s*(true|false)", body)
        return None if not m else (m.group(1) == "true")
    return {
        "id":            grab_str("id"),
        "name":          grab_str("name"),
        "version":       grab_str("version"),
        "description":   grab_str("description"),
        "license":       grab_str("license") or "unspecified",
        "prefix":        grab_str("prefix") or "/",
        "entry":         grab_str("entry") or "",
        "authors":       grab_array("authors"),
        "depends":       grab_pairs("depends"),
        "caps_required": grab_array("caps_required"),
        "caps_optional": grab_array("caps_optional"),
        "include":       grab_array("include") or ["**"],
        # Optional launcher/UI metadata. Forwarded verbatim into the
        # output manifest so pkg-installed apps integrate with the
        # desktop launcher (glyph + localization + sort order).
        "glyph":         grab_str("glyph"),
        "lang_key":      grab_str("lang_key"),
        "launcher_order": grab_int("launcher_order"),
        "hidden":        grab_bool("hidden"),
    }


def collect_files(root: Path, include: list[str], skip: list[str]) -> list[Path]:
    files = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        rel = str(path.relative_to(root)).replace("\\", "/")
        if any(fnmatch.fnmatch(rel, p) for p in skip):
            continue
        if any(fnmatch.fnmatch(rel, p) for p in include):
            files.append(path)
    return files


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("source", help="project directory containing manifest.cfg")
    p.add_argument("-o", "--output", required=True, help="output package directory")
    args = p.parse_args()

    src = Path(args.source).resolve()
    out = Path(args.output).resolve()
    if not (src / "manifest.cfg").exists():
        print(f"pack: missing manifest.cfg in {src}", file=sys.stderr); return 1

    info = read_manifest(src / "manifest.cfg")
    skip = ["manifest.cfg", "*.swp", ".git/**", ".DS_Store"]
    files = collect_files(src, info["include"], skip)

    out.mkdir(parents=True, exist_ok=True)
    file_entries = []
    for f in files:
        rel = str(f.relative_to(src)).replace("\\", "/")
        digest = hashlib.sha256(f.read_bytes()).hexdigest()
        dest = out / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(f, dest)
        file_entries.append(f'    [{lua_str(rel)}] = {{ sha256 = {lua_str(digest)} }},')

    extra_lines = []
    if info["glyph"]:
        extra_lines.append(f"  glyph       = {lua_str(info['glyph'])},")
    if info["lang_key"]:
        extra_lines.append(f"  lang_key    = {lua_str(info['lang_key'])},")
    if info["launcher_order"] is not None:
        extra_lines.append(f"  launcher_order = {info['launcher_order']},")
    if info["hidden"] is not None:
        extra_lines.append(f"  hidden      = {str(info['hidden']).lower()},")
    extra_block = ("\n".join(extra_lines) + "\n") if extra_lines else ""

    rendered = LUA_TEMPLATE.format(
        id            = info["id"],
        name          = info["name"],
        version       = info["version"],
        description   = info["description"],
        license       = info["license"],
        prefix        = info["prefix"],
        entry         = info["entry"],
        authors       = lua_array(info["authors"]),
        depends       = lua_table_pairs(info["depends"]),
        caps_required = lua_array(info["caps_required"]),
        caps_optional = lua_array(info["caps_optional"]),
        files         = "\n".join(file_entries),
        extra         = extra_block,
    )
    (out / "manifest.cfg").write_text(rendered, encoding="utf-8")
    print(f"pack: wrote {out} ({len(files)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
