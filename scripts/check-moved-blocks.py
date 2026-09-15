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

2. A `moved` target that names no resource or module -- a typo, or a rename that
   was not carried through. The state object lands at an address nothing
   declares, so it is destroyed. Most targets here point *inside* a vendored
   module, so the resource is resolved through .terraform/modules/modules.json
   and checked there: `module.oxbow_queue[0].aws_sqs_queue.thsi` is the shape
   that matters, and checking only the module head misses it.

3. A `moved` target with an unusable index: an index on a resource that declares
   no count, or a counted module referenced without one. (An *unindexed*
   resource target is fine -- that is a whole-resource move, which keeps its
   keys; hazard 1 covers the case where the source has none to keep.)

4. Two `moved` blocks sharing one target, which collapses two objects onto one
   address.

5. A `removed` block without `lifecycle { destroy = false }`. That deletes the
   resource instead of forgetting it -- here, a live Delta lock table or a
   bucket's entire notification configuration.

It also checks the omission case, where a resource that existed before the
rewrite has no block at all and is silently destroyed.

Which prior resources existed and which carried a key is frozen in
prior-resources.txt rather than read from git: the pre-rewrite tree is
immutable, and shelling out to `git show main:` fails under a detached-HEAD
checkout and breaks outright once this branch merges.
"""

import json
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
# Anchored to one indent level: a nested `dynamic "x" { for_each = ... }` must
# not make its enclosing resource look counted.
COUNTED = re.compile(r"^[ \t]{1,2}(count|for_each)\s*=", re.M)
CHILD_TARGET = re.compile(r"^module\.([A-Za-z0-9_-]+)(\[[^\]]*\])?\.(.+)$")
INDEX = re.compile(r"\[([^\]]*)\]$")


def strip_index(address):
    return re.sub(r"\[[^\]]*\]", "", address)


def head_of(address):
    """The declared address a move target belongs to: module.X or type.name."""
    parts = address.split(".")
    return ".".join(parts[:2])


def index_problem(address, repetition):
    """Whether an address's instance key matches how the object is repeated.

    count takes integers and for_each strings, so `this[0]` on a for_each
    resource and `this["sqs"]` on a counted one are both addresses that do not
    exist -- which OpenTofu plans as a destroy rather than rejecting.
    """
    match = INDEX.search(address)
    if match is None:
        # Only reached for a module head, where the unindexed form names no
        # instance. For a resource it is a legal whole-resource move.
        return f"declares {repetition}, so it needs an index" if repetition else None
    key = match.group(1)
    quoted = key.startswith('"') and key.endswith('"')
    if repetition is None:
        return f"declares neither count nor for_each, so {address} is not an address"
    if repetition == "count" and quoted:
        return f"declares count, so its keys are integers, not {key}"
    if repetition == "for_each" and not quoted:
        return f'declares for_each, so its keys are strings, not {key}'
    return None


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


def declared_in(directory):
    """Declared addresses in one directory -> "count", "for_each" or None."""
    declared = {}
    for path in sorted(directory.glob("*.tf")):
        for kind, first, second, body in DECL.findall(path.read_text()):
            address = f"{first}.{second}" if kind == "resource" else f"module.{first}"
            match = COUNTED.search(body)
            declared[address] = match.group(1) if match else None
    return declared


def load_config():
    if not sorted(TF_DIR.glob("*.tf")):
        sys.exit(f"no .tf files in {TF_DIR}; refusing to pass vacuously")
    return declared_in(TF_DIR)


def load_module_dirs():
    """Child module name -> its source directory, from `tofu init`'s manifest."""
    manifest = TF_DIR / ".terraform" / "modules" / "modules.json"
    if not manifest.is_file():
        return None
    return {
        entry["Key"]: TF_DIR / entry["Dir"]
        for entry in json.loads(manifest.read_text())["Modules"]
        if entry.get("Key")
    }


def child_target_problem(to, module_dirs):
    """Resolve a target inside a child module and check it names a real address.

    Most targets here are of this shape, and it is the half no other tool sees:
    the module head can be perfectly valid while the resource inside it is a
    typo, which OpenTofu plans as a destroy.
    """
    match = CHILD_TARGET.match(to)
    if not match:
        return None
    name, _, inner = match.groups()
    directory = module_dirs.get(name)
    if directory is None or not directory.is_dir():
        return f"module {name} is not initialised; run `tofu init` before the guard"

    inner_head = head_of(inner)
    bare = strip_index(inner_head)
    declared = declared_in(directory)
    if bare not in declared:
        return f"{bare} is not declared in module {name} ({directory})"

    repetition = declared[bare]
    # An unindexed resource target is a legal whole-resource move; only a module
    # needs its index. Hazard 1 covers a source with no key to carry over.
    if not inner_head.endswith("]") and not bare.startswith("module."):
        return None
    problem = index_problem(inner_head, repetition)
    return f"{bare} in module {name} {problem}" if problem else None


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

    module_dirs = load_module_dirs()
    if module_dirs is None:
        sys.exit(
            f"no {TF_DIR}/.terraform/modules/modules.json; run `tofu init` first, "
            "or the in-module half of every target goes unchecked"
        )

    problems = []
    sources = set()
    targets = {}
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

        # Hazards 2 and 3: the target must name something, with a usable index,
        # at the head and again inside the module the head names.
        head = head_of(to)
        bare = strip_index(head)
        if bare not in declared:
            target_problem = f"{bare} names no resource or module in {TF_DIR}"
        # A counted module's instances are module.X[k]; module.X alone is no
        # prefix for a resource inside it. Unlike a resource, where the
        # unindexed form is a legal whole-resource move that keeps its keys.
        elif head.endswith("]") or bare.startswith("module."):
            problem = index_problem(head, declared[bare])
            target_problem = f"{bare} {problem}" if problem else child_target_problem(to, module_dirs)
        else:
            target_problem = None

        if target_problem:
            problems.append(
                f"DESTROYS: {frm}\n       -> {to} ({where})\n       {target_problem}"
            )

        # Hazard 4: two blocks landing on one address.
        if to in targets:
            problems.append(
                f"DESTROYS: {frm} and {targets[to]} ({where})\n"
                f"       both move onto {to}; one object would overwrite the other"
            )
        targets[to] = frm

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
