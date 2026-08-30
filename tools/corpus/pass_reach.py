#!/usr/bin/env python3
"""How much of ponyc's corpus a checker can decide without checking bodies.

`SEMANTIC_DESIGN.md` question 5 proposes a first slice that lowers types,
builds method tables, reifies and subtypes, and does not look inside a method
body. What that slice can reach is not a guess: ponyc's own pass order answers
it. Everything the slice does happens at or before ponyc's `traits` pass, and
body checking is `expr`. So a case ponyc rejects by the end of `traits` is one
the slice could reject too, and a case that survives to `expr` is one it
cannot.

Agreement counts both verdicts. A case ponyc accepts is one a permissive
checker agrees with by finding nothing wrong, so the ceiling is every accepted
case plus the rejections reachable before `expr`.

Usage: pass_reach.py <corpus-dir> [--limit N]

Reads `manifest.tsv` written by `extract_corpus.py`.
"""

import subprocess
import sys
import os
import tempfile


LIMIT_PASS = "traits"

# ponyc's pass order, from `ponyc --help`. A suite whose own target is
# earlier than `traits` never runs the passes this measurement stops after,
# so asking whether it errors by `traits` compares against something ponyc
# does not itself do. Those cases are excluded and counted separately.
PASS_ORDER = [
    "parse", "syntax", "sugar", "scope", "import", "name",
    "typealias_recursion", "flatten", "traits", "refer", "expr",
    "completeness", "verify", "final", "c", "reach", "paint", "ir",
    "bitcode", "asm", "obj", "all",
]


def runs_traits(suite_pass):
    """Whether a suite's own target pass reaches `traits`."""
    if suite_pass not in PASS_ORDER:
        return False
    return PASS_ORDER.index(suite_pass) >= PASS_ORDER.index(LIMIT_PASS)


def run(case, limit, out_dir):
    """Whether ponyc reports an error for `case` when stopped after `limit`."""
    try:
        done = subprocess.run(
            ["ponyc", "--pass=" + limit, "--verbose=0", "-o", out_dir, case],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=60,
        )
    except subprocess.TimeoutExpired:
        return None

    return done.returncode != 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    corpus = sys.argv[1]
    limit = None

    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])

    rows = []
    with open(os.path.join(corpus, "manifest.tsv"), encoding="utf8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 5:
                rows.append(parts[:5])

    if limit:
        rows = rows[:limit]

    excluded = [r for r in rows if not runs_traits(r[3])]
    rows = [r for r in rows if runs_traits(r[3])]

    counts = {
        ("accept", True): 0,
        ("accept", False): 0,
        ("reject", True): 0,
        ("reject", False): 0,
    }
    timeouts = 0
    early = []

    with tempfile.TemporaryDirectory() as out_dir:
        for i, (suite, test, expect, _, case) in enumerate(rows):
            errs = run(case, LIMIT_PASS, out_dir)

            if errs is None:
                timeouts += 1
                continue

            counts[(expect, errs)] += 1

            if (expect == "reject") and errs:
                early.append((suite, test))

            if (i % 100) == 0:
                print(f"  {i}/{len(rows)}", file=sys.stderr)

    accepted = counts[("accept", True)] + counts[("accept", False)]
    rejected = counts[("reject", True)] + counts[("reject", False)]
    total = accepted + rejected

    print()
    print(f"cases {total}, timeouts {timeouts}, stopped after --pass={LIMIT_PASS}")
    print(f"excluded {len(excluded)} whose own suite stops before {LIMIT_PASS}")
    print()
    print(f"ponyc accepts, no error by {LIMIT_PASS}: "
          f"{counts[('accept', False)]}")
    print(f"ponyc accepts, error by {LIMIT_PASS}:    "
          f"{counts[('accept', True)]}  (the proxy is wrong for these)")
    print(f"ponyc rejects, error by {LIMIT_PASS}:    "
          f"{counts[('reject', True)]}  (reachable without bodies)")
    print(f"ponyc rejects, no error by {LIMIT_PASS}: "
          f"{counts[('reject', False)]}  (needs body checking)")
    print()

    ceiling = counts[("accept", False)] + counts[("reject", True)]
    print(f"ceiling for a checker that stops before bodies: "
          f"{ceiling}/{total} = {100.0 * ceiling / total:.1f}%")
    print(f"of that, agreement bought by accepting everything: "
          f"{accepted}/{total} = {100.0 * accepted / total:.1f}%")
    print(f"rejections it adds over accepting everything:     "
          f"{counts[('reject', True)]}")

    by_suite = {}
    for suite, _ in early:
        by_suite[suite] = by_suite.get(suite, 0) + 1

    print()
    print("rejections reachable before bodies, by suite:")
    for suite, n in sorted(by_suite.items(), key=lambda kv: -kv[1]):
        print(f"  {suite:28s} {n}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
