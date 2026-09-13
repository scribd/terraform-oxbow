#!/usr/bin/env python3
"""Fail if a `moved` block would destroy the resource it claims to relocate.

A moved source with no instance key must name the target *instance*
(`module.x[0].res.name[0]`), not the resource (`module.x[0].res.name`). Moving a
keyless state object onto a counted resource lands it at the no-key address and
OpenTofu then destroys it -- silently, and invisibly to `tofu test`, because
state moves only manifest against real prior state.

Sources that carried count/for_each in the previous layout keep their key across
a whole-resource move, so those targets are correctly unindexed.
"""
import re
import subprocess
import sys

PRIOR_REF = "main"
PRIOR_FILES = ["main.tf", "autotagging.tf", "glue_create.tf", "glue_sync.tf", "monitoring.tf"]


def prior_source():
    out = []
    for f in PRIOR_FILES:
        r = subprocess.run(["git", "show", f"{PRIOR_REF}:{f}"], capture_output=True, text=True)
        if r.returncode == 0:
            out.append(r.stdout)
    return "\n".join(out)


def keyed_in_prior(src):
    keyed = set()
    for m in re.finditer(r'(?:resource|data)\s+"(\w+)"\s+"(\w+)"\s*\{(.*?)\n\}', src, re.S):
        typ, name, body = m.groups()
        if re.search(r"^\s+(count|for_each)\s*=", body, re.M):
            keyed.add(f"{typ}.{name}")
    return keyed


def main():
    blocks = re.findall(
        r"moved\s*\{\s*from\s*=\s*([^\n]+)\n\s*to\s*=\s*([^\n]+)", open("moved.tf").read()
    )
    if not blocks:
        sys.exit("no moved blocks found -- is moved.tf still there?")

    keyed = keyed_in_prior(prior_source())
    bad = []
    for frm, to in blocks:
        frm, to = frm.strip(), to.strip()
        source_has_key = frm.endswith("]") or re.sub(r"\[.*\]$", "", frm) in keyed
        if not source_has_key and not to.endswith("]"):
            bad.append((frm, to))

    for frm, to in bad:
        print(f"DESTROYS: {frm}\n       -> {to}\n       target must name the instance, e.g. {to}[0]\n")
    print(f"checked {len(blocks)} moved blocks, {len(bad)} would destroy")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
