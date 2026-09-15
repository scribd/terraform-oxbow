#!/usr/bin/env python3
"""Guard the state-move hazards that `tofu validate` and `tofu test` cannot reach.

State moves only manifest against real prior state, so neither validate nor the
test suite sees them. Four mistakes here destroy live infrastructure, and none
of them is a configuration error -- a `moved` block whose target names nothing
at all still passes `tofu validate`:

1. A `moved` source with no instance key targeting a whole counted resource.
   The object lands at the no-key address and OpenTofu destroys it. Verified
   against OpenTofu 1.12.6: the indexed form moves in place, the unindexed form
   plans `1 to add, 1 to destroy`.

2. A `moved` target that names no resource or module in the configuration --
   a typo, or a rename that was not carried through. The state object lands at
   an address nothing declares, so it is destroyed.

3. A `moved` target with an unusable index: an index on a resource that declares
   no count, or a counted module referenced without one. (An *unindexed*
   resource target is fine -- that is a whole-resource move, which keeps its
   keys; hazard 1 covers the case where the source has none to keep.)

4. A `removed` block without `lifecycle { destroy = false }`. That deletes the
   resource instead of forgetting it -- here, a live Delta lock table or a
   bucket's entire notification configuration.

It also checks the omission case, where a resource that existed before the
rewrite has no block at all and is silently destroyed.

Which prior resources existed and which carried a key is frozen in
prior-resources.txt rather than read from git: the pre-rewrite tree is
immutable, and shelling out to `git show main:` fails under a detached-HEAD
checkout and breaks outright once this branch merges.
"""

import os
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
TF_DIR = pathlib.Path(os.environ.get("TF_DIR", HERE.parent))
PRIOR_FILE = pathlib.Path(os.environ.get("PRIOR_FILE", HERE / "prior-resources.txt"))

# Prior addresses this rewrite destroys on purpose. Both granted
# s3.amazonaws.com the right to invoke a function that is only ever driven by an
# SQS event source mapping, so nothing exercised them. See UPGRADING.md.
INTENTIONAL_DESTROYS = {
    "aws_lambda_permission.this_lambda_allow_bucket_permissions",
    "aws_lambda_permission.auto_tagging",
}

BLOCK = re.compile(r"^(moved|removed)\s*\{(.*?)^\}", re.S | re.M)
ATTR = re.compile(r"^\s*(from|to)\s*=\s*(\S+)\s*$", re.M)
DESTROY_FALSE = re.compile(r"lifecycle\s*\{[^}]*\bdestroy\s*=\s*false\b", re.S)
DECL = re.compile(
    r'^(resource|module)\s+"([^"]+)"(?:\s+"([^"]+)")?\s*\{(.*?)^\}', re.S | re.M
)
COUNTED = re.compile(r"^\s*(count|for_each)\s*=", re.M)


def strip_index(address):
    return re.sub(r"\[[^\]]*\]", "", address)


def head_of(address):
    """The declared address a move target belongs to: module.X or type.name."""
    parts = address.split(".")
    return ".".join(parts[:2])


def load_prior():
    if not PRIOR_FILE.is_file():
        sys.exit(f"missing {PRIOR_FILE}; cannot tell what the prior layout held")
    prior = {}
    for line in PRIOR_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        flag, _, address = line.partition(" ")
        address = address.strip()
        if flag not in ("keyed", "unkeyed") or not address:
            sys.exit(f"{PRIOR_FILE}: cannot parse {line!r}")
        prior[address] = flag == "keyed"
    if not prior:
        sys.exit(f"{PRIOR_FILE} lists no resources; refusing to pass vacuously")
    return prior


def load_config():
    """Declared addresses in TF_DIR, mapped to whether they are counted."""
    declared = {}
    files = sorted(TF_DIR.glob("*.tf"))
    if not files:
        sys.exit(f"no .tf files in {TF_DIR}; refusing to pass vacuously")
    for path in files:
        for kind, first, second, body in DECL.findall(path.read_text()):
            address = f"{first}.{second}" if kind == "resource" else f"module.{first}"
            declared[address] = bool(COUNTED.search(body))
    return declared


def load_blocks():
    blocks = []
    for path in sorted(TF_DIR.glob("*.tf")):
        for kind, body in BLOCK.findall(path.read_text()):
            blocks.append((path.name, kind, body))
    if not blocks:
        sys.exit("no moved or removed blocks parsed -- the guard would pass vacuously")
    return blocks


def main():
    prior = load_prior()
    declared = load_config()
    blocks = load_blocks()

    problems = []
    sources = set()
    moved = removed = 0

    for filename, kind, body in blocks:
        attrs = dict(ATTR.findall(body))
        where = f"{filename}"

        if kind == "removed":
            removed += 1
            frm = attrs.get("from")
            if not frm:
                problems.append(f"{where}: removed block missing from:\n{body.strip()}")
                continue
            sources.add(strip_index(frm))
            if not DESTROY_FALSE.search(body):
                problems.append(
                    f"DESTROYS: removed {frm} ({where})\n"
                    f"       needs lifecycle {{ destroy = false }} to forget rather than delete"
                )
            continue

        moved += 1
        frm, to = attrs.get("from"), attrs.get("to")
        if not frm or not to:
            problems.append(f"{where}: moved block missing from/to:\n{body.strip()}")
            continue
        sources.add(strip_index(frm))

        # Hazard 1: a keyless source landing on a counted resource.
        source_has_key = frm.endswith("]") or prior.get(strip_index(frm), False)
        if not source_has_key and not to.endswith("]"):
            problems.append(
                f"DESTROYS: {frm}\n       -> {to} ({where})\n"
                f"       source has no instance key, so the target must name one: {to}[0]"
            )

        # Hazards 2 and 3: the target must name something, with a usable index.
        head = head_of(to)
        bare = strip_index(head)
        indexed = head.endswith("]")
        if bare not in declared:
            problems.append(
                f"DESTROYS: {frm}\n       -> {to} ({where})\n"
                f"       {bare} names no resource or module in {TF_DIR}"
            )
        elif indexed and not declared[bare]:
            problems.append(
                f"DESTROYS: {frm}\n       -> {to} ({where})\n"
                f"       {bare} declares no count, so {head} is not an address"
            )
        elif bare.startswith("module.") and declared[bare] and not indexed:
            # A counted module's instances are module.X[k]; module.X alone is no
            # prefix for a resource inside it. Unlike a resource, where the
            # unindexed form is a legal whole-resource move that keeps its keys.
            problems.append(
                f"DESTROYS: {frm}\n       -> {to} ({where})\n"
                f"       {bare} declares count, so the target must be written {bare}[0]..."
            )

    # The omission case: a prior resource with no block and no surviving
    # declaration at the same address is destroyed without anyone saying so.
    for address in sorted(prior):
        if address in sources or address in declared or address in INTENTIONAL_DESTROYS:
            continue
        problems.append(
            f"DESTROYS: {address}\n"
            f"       existed before the rewrite with no moved or removed block, and no\n"
            f"       longer declared. Add a block, or list it in INTENTIONAL_DESTROYS."
        )

    for problem in problems:
        print(problem + "\n")
    print(
        f"checked {moved} moved and {removed} removed blocks against "
        f"{len(prior)} prior addresses, {len(problems)} would destroy"
    )
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
