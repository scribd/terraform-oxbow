#!/usr/bin/env python3
"""Fixtures for check-moved-blocks.py. It guards a destroy-live-resources
failure mode nothing else checks, so it needs its own tests."""

import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
GUARD = HERE / "check-moved-blocks.py"
KEYED = "aws_sqs_queue.keyed_in_prior\n"

CASES = [
    # (name, moved.tf body, keyed file contents, expected exit)
    ("keyless source onto whole counted resource is rejected", '''
moved {
  from = aws_lambda_function.was_not_counted
  to   = module.m[0].aws_lambda_function.this
}
''', KEYED, 1),
    ("keyless source onto an explicit instance is accepted", '''
moved {
  from = aws_lambda_function.was_not_counted
  to   = module.m[0].aws_lambda_function.this[0]
}
''', KEYED, 0),
    ("keyed source onto a whole resource is accepted", '''
moved {
  from = aws_sqs_queue.keyed_in_prior
  to   = module.m[0].aws_sqs_queue.this
}
''', KEYED, 0),
    ("for_each key on the target is accepted", '''
moved {
  from = aws_lambda_event_source_mapping.was_not_counted
  to   = module.m[0].aws_lambda_event_source_mapping.this["sqs"]
}
''', KEYED, 0),
    ("to before from is still parsed", '''
moved {
  to   = module.m[0].aws_lambda_function.this
  from = aws_lambda_function.was_not_counted
}
''', KEYED, 1),
    ("removed without destroy = false is rejected", '''
removed {
  from = aws_dynamodb_table.gone
}
''', KEYED, 1),
    ("removed with destroy = false is accepted", '''
removed {
  from = aws_dynamodb_table.gone

  lifecycle {
    destroy = false
  }
}
''', KEYED, 0),
    ("removed with destroy = true is rejected", '''
removed {
  from = aws_dynamodb_table.gone

  lifecycle {
    destroy = true
  }
}
''', KEYED, 1),
    ("a file with no blocks errors rather than passing vacuously", "# nothing here\n", KEYED, 1),
    ("an empty keyed list errors rather than passing vacuously", '''
moved {
  from = aws_sqs_queue.keyed_in_prior
  to   = module.m[0].aws_sqs_queue.this
}
''', "# no entries\n", 1),
]


def main():
    failures = 0
    for name, moved_body, keyed_body, want in CASES:
        with tempfile.TemporaryDirectory() as d:
            d = pathlib.Path(d)
            (d / "moved.tf").write_text(moved_body)
            (d / "keyed.txt").write_text(keyed_body)
            r = subprocess.run(
                [sys.executable, str(GUARD)],
                capture_output=True, text=True,
                env={"PATH": "/usr/bin:/bin", "MOVED_TF": str(d / "moved.tf"),
                     "KEYED_FILE": str(d / "keyed.txt")},
            )
            ok = r.returncode == want
            failures += 0 if ok else 1
            print(f"{'ok  ' if ok else 'FAIL'}  {name} (exit {r.returncode}, want {want})")
            if not ok:
                print("      " + (r.stdout + r.stderr).replace("\n", "\n      ").strip())
    print(f"\n{len(CASES) - failures}/{len(CASES)} passed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
