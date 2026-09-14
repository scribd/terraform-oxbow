#!/usr/bin/env python3
"""Guard the two state-move hazards that `tofu test` cannot reach.

State moves only manifest against real prior state, so neither `tofu validate`
nor the test suite sees them. Two mistakes here destroy live infrastructure:

1. A `moved` source with no instance key targeting a whole counted resource.
   The object lands at the no-key address and OpenTofu destroys it. Verified
   against OpenTofu 1.12.6: the indexed form moves in place, the unindexed form
   plans `1 to add, 1 to destroy`.

2. A `removed` block without `lifecycle { destroy = false }`. That deletes the
   resource instead of forgetting it -- here, a live Delta lock table or a
   bucket's entire notification configuration.

Which prior resources carried a key is frozen in prior-keyed-resources.txt
rather than read from git: the pre-rewrite tree is immutable, and shelling out
to `git show main:` fails under a detached-HEAD checkout and breaks outright
once this branch merges.
"""

import os
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
MOVED_TF = pathlib.Path(os.environ.get("MOVED_TF", HERE.parent / "moved.tf"))
KEYED_FILE = pathlib.Path(os.environ.get("KEYED_FILE", HERE / "prior-keyed-resources.txt"))

BLOCK = re.compile(r"^(moved|removed)\s*\{(.*?)^\}", re.S | re.M)
ATTR = re.compile(r"^\s*(from|to)\s*=\s*(\S+)\s*$", re.M)
DESTROY_FALSE = re.compile(r"lifecycle\s*\{[^}]*\bdestroy\s*=\s*false\b", re.S)


def load_keyed():
    if not KEYED_FILE.is_file():
        sys.exit(f"missing {KEYED_FILE}; cannot tell which prior resources were keyed")
    lines = [l.strip() for l in KEYED_FILE.read_text().splitlines()]
    keyed = {l for l in lines if l and not l.startswith("#")}
    if not keyed:
        sys.exit(f"{KEYED_FILE} lists no resources; refusing to pass vacuously")
    return keyed


def main():
    if not MOVED_TF.is_file():
        sys.exit(f"missing {MOVED_TF}")
    keyed = load_keyed()

    blocks = BLOCK.findall(MOVED_TF.read_text())
    if not blocks:
        sys.exit("no moved or removed blocks parsed -- the guard would pass vacuously")

    problems = []
    moved = removed = 0
    for kind, body in blocks:
        attrs = dict(ATTR.findall(body))
        if kind == "moved":
            moved += 1
            frm, to = attrs.get("from"), attrs.get("to")
            if not frm or not to:
                problems.append(f"moved block missing from/to:\n{body.strip()}")
                continue
            source_has_key = frm.endswith("]") or re.sub(r"\[.*\]$", "", frm) in keyed
            if not source_has_key and not to.endswith("]"):
                problems.append(
                    f"DESTROYS: {frm}\n       -> {to}\n"
                    f"       source has no instance key, so the target must name one: {to}[0]"
                )
        else:
            removed += 1
            frm = attrs.get("from")
            if not frm:
                problems.append(f"removed block missing from:\n{body.strip()}")
                continue
            if not DESTROY_FALSE.search(body):
                problems.append(
                    f"DESTROYS: removed {frm}\n"
                    f"       needs lifecycle {{ destroy = false }} to forget rather than delete"
                )

    for p in problems:
        print(p + "\n")
    print(f"checked {moved} moved and {removed} removed blocks, {len(problems)} would destroy")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
