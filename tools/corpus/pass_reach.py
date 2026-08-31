#!/usr/bin/env python3
"""The per-case corpus instrument.

For every extracted case this records, empirically, what ponyc does with
it: whether an accept case really compiles to its own target pass and
whether full ponyc still accepts it, the earliest pass at which a reject
case errors, and whether the rejection came from the #1216
recursion-divergence guard. The summary numbers are derived from the
per-case records, and the records are written to `reach.tsv` beside the
manifest so a later run can be diffed per case rather than compared as
an aggregate.

`reach.tsv` columns, tab-separated, no header, one payload column per
row kind so no column carries two vocabularies:
  1  suite
  2  test
  3  expected verdict: accept, reject, or invalid (see below)
  4  the case's own target pass
  5  accept rows: `limited` when full ponyc (--pass=final) rejects the
     case, else `-`; `-` on other rows
  6  reject rows: the earliest pass that errors; `-` on other rows
  7  invalid rows: the reason; `-` on other rows
  8  `guard` when the rejection came from ponyc's #1216 divergence
     guard, else `-`

A case is *invalid* when ponyc disagrees with the verdict its own test
asserts — an accept that errors at its target pass, or a reject that
does not. Those are extraction or environment drift (the known shape: a
case that redeclares a builtin name compiles under the unit-test harness
but not standalone). They are excluded from every number, listed, and
written to `reach.tsv` as invalid rows so a scoring run can tell an
excluded case from a case this instrument never saw.

Slice attribution: a reject belongs to the earliest pass that errors on
it. Slice 0 of `SEMANTIC_DESIGN.md` covers parse and syntax legality;
slice 1 covers sugar, scope, import and name; slice 2 covers
typealias_recursion, flatten and traits; everything later needs bodies.
The checker's slice 0 also includes `use` resolution, which errors at
the scope and import passes in ponyc, so the slice-0 line below is not
that checker's ceiling — the per-pass agreement table in
corpus_report.py is what shows where credit comes from.

--limit truncates to the first N manifest rows for a quick look, and
writes `reach.partial.tsv` instead, so a debug run cannot overwrite the
full instrument.

Usage: pass_reach.py <corpus-dir> [--limit N]
"""

import os
import re
import subprocess
import sys
import tempfile

LADDER = [
    "parse", "syntax", "sugar", "scope", "import", "name",
    "typealias_recursion", "flatten", "traits", "refer", "expr",
    "completeness", "verify", "final", "c", "reach", "paint", "ir",
]

SLICE0 = {"parse", "syntax"}
SLICE1 = {"sugar", "scope", "import", "name"}
SLICE2 = {"typealias_recursion", "flatten", "traits"}

GUARD = re.compile(r"same-def\s+frames|ponylang/ponyc#1216")


def run(case, limit, out_dir):
    """ponyc's exit and stderr for `case` stopped after `limit`."""
    try:
        done = subprocess.run(
            ["ponyc", "--pass=" + limit, "--verbose=0", "-o", out_dir, case],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        return None, ""
    return done.returncode != 0, done.stderr.decode("utf8", "replace")


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

    records = []
    invalid = []
    timeouts = 0

    with tempfile.TemporaryDirectory() as out_dir:
        for i, (suite, test, expect, target, case) in enumerate(rows):
            if target not in LADDER:
                invalid.append((suite, test, "unknown target " + target))
                records.append(
                    (suite, test, "invalid", target, "-", "-",
                     "unknown target", "-"))
                continue
            target_i = LADDER.index(target)

            if expect == "accept":
                errs, _ = run(case, target, out_dir)
                if errs is None:
                    timeouts += 1
                    records.append(
                        (suite, test, "invalid", target, "-", "-",
                         "timeout", "-"))
                    continue
                if errs:
                    invalid.append(
                        (suite, test, "accept errors at " + target))
                    records.append(
                        (suite, test, "invalid", target, "-", "-",
                         "accept errors at " + target, "-"))
                    continue
                # An accept is asserted only through its own target
                # pass, but a checker checks the whole program, so
                # record what full ponyc reports as well: a "limited"
                # accept is one full ponyc rejects, and a checker
                # agreeing with full ponyc there is not wrong. "Full"
                # is the last front-end pass, `final` -- anything later
                # needs a Main actor, which library-shaped cases
                # legitimately lack.
                if target_i < LADDER.index("final"):
                    full_errs, _ = run(case, "final", out_dir)
                    if full_errs is None:
                        timeouts += 1
                        records.append(
                            (suite, test, "invalid", target, "-", "-",
                             "timeout", "-"))
                        continue
                    full = "limited" if full_errs else "-"
                else:
                    full = "-"
                records.append(
                    (suite, test, expect, target, full, "-", "-", "-"))
            else:
                earliest = None
                guard = "-"
                for p in LADDER[: target_i + 1]:
                    errs, stderr = run(case, p, out_dir)
                    if errs is None:
                        timeouts += 1
                        earliest = "timeout"
                        break
                    if errs:
                        earliest = p
                        if GUARD.search(stderr):
                            guard = "guard"
                        break
                if earliest is None:
                    invalid.append(
                        (suite, test, "reject clean through " + target))
                    records.append(
                        (suite, test, "invalid", target, "-", "-",
                         "reject clean through " + target, "-"))
                    continue
                if earliest == "timeout":
                    records.append(
                        (suite, test, "invalid", target, "-", "-",
                         "timeout", "-"))
                    continue
                records.append(
                    (suite, test, expect, target, "-", earliest, "-",
                     guard))

            if (i % 100) == 0:
                print(f"  {i}/{len(rows)}", file=sys.stderr)

    out_name = "reach.partial.tsv" if limit else "reach.tsv"
    with open(os.path.join(corpus, out_name), "w", encoding="utf8") as f:
        for row in records:
            f.write("\t".join(row) + "\n")

    accepts = sum(1 for r in records if r[2] == "accept")
    limited = sum(
        1 for r in records if (r[2] == "accept") and (r[4] == "limited"))
    rejects = [r for r in records if r[2] == "reject"]
    universe = accepts + len(rejects)
    s0 = sum(1 for r in rejects if r[5] in SLICE0)
    s1 = sum(1 for r in rejects if r[5] in SLICE1)
    s2 = sum(1 for r in rejects if r[5] in SLICE2)
    later = len(rejects) - s0 - s1 - s2
    guard_hits = [r for r in rejects if r[7] == "guard"]

    def pts(n):
        return 100.0 * n / universe

    print()
    print(f"cases {len(rows)}, valid {universe}, "
          f"invalid {len(invalid)}, timeouts {timeouts}")
    print(f"per-case records written to {out_name}")
    print()
    print(f"floor -- accepts, agreed with by rejecting nothing: "
          f"{accepts}/{universe} = {pts(accepts):.1f}%")
    print(f"of which pass-limited (full ponyc rejects): {limited}")
    print(f"on the scored scale, where a limited accept expects reject:")
    print(f"  accept-everything scores "
          f"{pts(accepts - limited):.1f}%, "
          f"reject-everything {pts((universe - accepts) + limited):.1f}%")
    print(f"slice 0 (parse, syntax):              "
          f"{s0}  (+{pts(s0):.1f} points)")
    print(f"slice 1 (sugar, scope, import, name): "
          f"{s1}  (+{pts(s1):.1f} points)")
    print(f"slice 2 (typealias, flatten, traits): "
          f"{s2}  (+{pts(s2):.1f} points)")
    print(f"needs bodies (refer and later):       {later}")
    print(f"cumulative ceiling through slice 2:   "
          f"{accepts + s0 + s1 + s2}/{universe} = "
          f"{pts(accepts + s0 + s1 + s2):.1f}%")
    print()
    print(f"rejections decided by the #1216 divergence guard: "
          f"{len(guard_hits)}")
    for suite, test, _, _, _, _, _, _ in guard_hits:
        print(f"  {suite}/{test}")

    if invalid:
        print()
        print(f"invalid cases, excluded from every number:")
        for suite, test, why in invalid:
            print(f"  {suite}/{test}: {why}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
