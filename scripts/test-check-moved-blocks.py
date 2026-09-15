#!/usr/bin/env python3
"""Fixtures for check-moved-blocks.py. It guards a destroy-live-resources
failure mode nothing else checks -- `tofu validate` accepts every one of the
rejected cases below -- so it needs its own tests."""

import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
GUARD = HERE / "check-moved-blocks.py"

# Stands in for the real configuration: a counted module, an uncounted one, a
# counted resource and an uncounted one.
DECLARATIONS = """
module "m" {
  source = "./m"
  count  = 1
}

module "plain" {
  source = "./plain"
}

resource "aws_sqs_queue" "counted" {
  count = 1
}

resource "aws_sqs_queue" "solo" {
  name = "solo"
}
"""

KEYED = "keyed   aws_sqs_queue.keyed_in_prior\n"
UNKEYED = "unkeyed aws_lambda_function.was_not_counted\n"
ESM = "unkeyed aws_lambda_event_source_mapping.was_not_counted\n"
GONE = "unkeyed aws_dynamodb_table.gone\n"

CASES = [
    # (name, blocks, prior file contents, expected exit)
    ("keyless source onto whole counted resource is rejected", '''
moved {
  from = aws_lambda_function.was_not_counted
  to   = module.m[0].aws_lambda_function.this
}
''', UNKEYED, 1),
    ("keyless source onto an explicit instance is accepted", '''
moved {
  from = aws_lambda_function.was_not_counted
  to   = module.m[0].aws_lambda_function.this[0]
}
''', UNKEYED, 0),
    ("keyed source onto a whole resource is accepted", '''
moved {
  from = aws_sqs_queue.keyed_in_prior
  to   = aws_sqs_queue.counted
}
''', KEYED, 0),
    ("for_each key on the target is accepted", '''
moved {
  from = aws_lambda_event_source_mapping.was_not_counted
  to   = module.m[0].aws_lambda_event_source_mapping.this["sqs"]
}
''', ESM, 0),
    ("to before from is still parsed", '''
moved {
  to   = module.m[0].aws_lambda_function.this
  from = aws_lambda_function.was_not_counted
}
''', UNKEYED, 1),

    # Hazard 2: a target that names nothing. This is the shape that destroyed
    # the live oxbow lambda once already -- one transposed letter.
    ("a target naming no resource or module is rejected", '''
moved {
  from = aws_sqs_queue.keyed_in_prior
  to   = module.typo[0].aws_sqs_queue.this
}
''', KEYED, 1),
    ("a target resource that does not exist is rejected", '''
moved {
  from = aws_sqs_queue.keyed_in_prior
  to   = aws_sqs_queue.does_not_exist
}
''', KEYED, 1),

    # Hazard 3: an index that is not an address.
    ("an index on an uncounted resource is rejected", '''
moved {
  from = aws_sqs_queue.keyed_in_prior
  to   = aws_sqs_queue.solo[0]
}
''', KEYED, 1),
    ("a counted module referenced without an index is rejected", '''
moved {
  from = aws_sqs_queue.keyed_in_prior
  to   = module.m.aws_sqs_queue.this[0]
}
''', KEYED, 1),
    ("an uncounted module referenced without an index is accepted", '''
moved {
  from = aws_sqs_queue.keyed_in_prior
  to   = module.plain.aws_sqs_queue.this[0]
}
''', KEYED, 0),

    ("removed without destroy = false is rejected", '''
removed {
  from = aws_dynamodb_table.gone
}
''', GONE, 1),
    ("removed with destroy = false is accepted", '''
removed {
  from = aws_dynamodb_table.gone

  lifecycle {
    destroy = false
  }
}
''', GONE, 0),
    ("removed with destroy = true is rejected", '''
removed {
  from = aws_dynamodb_table.gone

  lifecycle {
    destroy = true
  }
}
''', GONE, 1),

    # The omission case: nothing in the diff says this resource is going away.
    ("a prior resource with no block at all is rejected", '''
moved {
  from = aws_sqs_queue.keyed_in_prior
  to   = aws_sqs_queue.counted
}
''', KEYED + "keyed   aws_sqs_queue.forgotten\n", 1),
    ("a prior resource still declared at the same address is accepted", '''
moved {
  from = aws_sqs_queue.keyed_in_prior
  to   = aws_sqs_queue.counted
}
''', KEYED + "keyed   aws_sqs_queue.solo\n", 0),
    ("a prior resource on the intentional-destroy list is accepted", '''
moved {
  from = aws_sqs_queue.keyed_in_prior
  to   = aws_sqs_queue.counted
}
''', KEYED + "unkeyed aws_lambda_permission.auto_tagging\n", 0),

    ("no blocks anywhere errors rather than passing vacuously", "# nothing here\n", KEYED, 1),
    ("an empty prior list errors rather than passing vacuously", '''
moved {
  from = aws_sqs_queue.keyed_in_prior
  to   = aws_sqs_queue.counted
}
''', "# no entries\n", 1),
    ("an unparseable prior line errors", '''
moved {
  from = aws_sqs_queue.keyed_in_prior
  to   = aws_sqs_queue.counted
}
''', "aws_sqs_queue.no_flag_column\n", 1),
]

# A block in any .tf file counts, so the guard must not read moved.tf alone.
STRAY_FILE_CASE = ('''
moved {
  from = aws_lambda_function.was_not_counted
  to   = module.m[0].aws_lambda_function.this
}
''', UNKEYED, 1)


def run(blocks, prior, blocks_filename="moved.tf"):
    with tempfile.TemporaryDirectory() as d:
        d = pathlib.Path(d)
        (d / "declarations.tf").write_text(DECLARATIONS)
        (d / blocks_filename).write_text(blocks)
        (d / "prior.txt").write_text(prior)
        return subprocess.run(
            [sys.executable, str(GUARD)],
            capture_output=True, text=True,
            env={"PATH": "/usr/bin:/bin", "TF_DIR": str(d),
                 "PRIOR_FILE": str(d / "prior.txt")},
        )


def main():
    failures = 0
    cases = [(n, b, p, w, "moved.tf") for n, b, p, w in CASES]
    blocks, prior, want = STRAY_FILE_CASE
    cases.append(
        ("a block in a file other than moved.tf is still checked",
         blocks, prior, want, "oxbow.tf")
    )

    for name, blocks, prior, want, filename in cases:
        r = run(blocks, prior, filename)
        ok = r.returncode == want
        failures += 0 if ok else 1
        print(f"{'ok  ' if ok else 'FAIL'}  {name} (exit {r.returncode}, want {want})")
        if not ok:
            print("      " + (r.stdout + r.stderr).replace("\n", "\n      ").strip())

    print(f"\n{len(cases) - failures}/{len(cases)} passed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
