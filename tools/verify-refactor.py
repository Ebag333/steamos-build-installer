#!/usr/bin/env python3
"""verify-refactor.py — make sure the refactor lost no functionality.

Compares the original monolith (steamos-nvidia-installer.sh.orig) against the
refactored wrapper + lib/*.sh.

How it works: strip blank lines and comment-only lines, dedent the rest, then
compare the *multiset* of functional lines.

  * Any line present in the original but missing (or present fewer times) in
    the refactor means functionality was LOST -> exit 1.
  * Lines only present in the refactor are expected additions (new function
    definitions, sourcing, orchestration calls) and are printed for review.

Re-run this after every future edit to prove nothing regressed.

Usage:  python3 tools/verify-refactor.py
"""
import collections
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ORIG = ROOT / "steamos-nvidia-installer.sh.orig"
NEW = [ROOT / "steamos-nvidia-installer.sh"] + sorted((ROOT / "lib").glob("*.sh"))


def normalize(lines):
    out = []
    for ln in lines:
        s = ln.rstrip("\n").lstrip()
        if not s or s.startswith("#"):
            continue
        out.append(s)
    return out


orig_lines = normalize(ORIG.read_text(encoding="utf-8").splitlines(True))
new_lines = []
for f in NEW:
    new_lines += normalize(f.read_text(encoding="utf-8").splitlines(True))

orig_counter = collections.Counter(orig_lines)
new_counter = collections.Counter(new_lines)

missing = orig_counter - new_counter
added = new_counter - orig_counter

if not ORIG.exists():
    sys.exit("verification requires steamos-nvidia-installer.sh.orig "
             "(the pristine pre-refactor copy) next to this script")

if missing:
    n = sum(missing.values())
    print(f"LOST FUNCTIONALITY: {n} line(s) from the original are missing", flush=True)
    for line, count in sorted(missing.items()):
        print(f"  x{count:3d}  {line}", flush=True)
    sys.exit(1)

print(f"OK: all {len(orig_lines)} functional lines of the original are present "
      f"in the refactor.", flush=True)
if added:
    n = sum(added.values())
    print(f"{n} added line(s) present only in the refactor "
          f"(expected: function defs, sourcing, orchestration calls):", flush=True)
    for line, count in sorted(added.items()):
        print(f"  +{count:3d}  {line}", flush=True)
sys.exit(0)