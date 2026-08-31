#!/usr/bin/env python3
"""Compare ponyq's accept/reject verdict against ponyc's on the test corpus.

Reads the manifest written by extract_corpus.py and the verdicts written by
`ponyq check --batch`, and reports the agreement rate per suite.

Usage: corpus_report.py <manifest.tsv> <verdicts.tsv> [--suites a,b,c] [--list]
"""

import collections
import sys


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = [a for a in sys.argv[1:] if a.startswith("--")]

    if len(args) < 2:
        print(__doc__)
        return 1

    only = None
    limited = set()
    universe = None

    for f in flags:
        if f.startswith("--suites="):
            only = set(f.split("=", 1)[1].split(","))
        if f.startswith("--reach="):
            # reach.tsv is the per-case instrument: it holds only the
            # cases standalone ponyc validates, so scoring restricts to
            # them, and it marks accepts that full ponyc rejects -- a
            # checker rejecting one of those agrees with ponyc, not with
            # the case's pass-limited contract, so the expectation flips.
            universe = set()
            for line in open(f.split("=", 1)[1], encoding="utf8"):
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 5:
                    universe.add((parts[0], parts[1]))
                    if parts[4] == "limited":
                        limited.add((parts[0], parts[1]))

    verdicts = {}

    for line in open(args[1], encoding="utf8"):
        parts = line.rstrip("\n").split("\t")

        if len(parts) == 2:
            verdicts[parts[0]] = parts[1]

    by_suite = collections.defaultdict(lambda: [0, 0])
    disagreements = []
    missing = []

    for line in open(args[0], encoding="utf8"):
        parts = line.rstrip("\n").split("\t")
        suite, test, expect, cpass, path = parts[:5]
        message = parts[5] if len(parts) > 5 else ""

        if only is not None and suite not in only:
            continue

        if (universe is not None) and ((suite, test) not in universe):
            continue

        got = verdicts.get(path)

        if got is None:
            missing.append((suite, test))
            continue

        if (suite, test) in limited:
            expect = "reject"

        ours = "accept" if got == "ok" else "reject"
        by_suite[suite][1] += 1

        if ours == expect:
            by_suite[suite][0] += 1
        else:
            disagreements.append((suite, test, expect, ours, cpass, message))

    # A verdict file that stops early -- a mid-batch crash -- must fail
    # loudly, not yield an agreement rate over the surviving prefix.
    if missing:
        print(f"INCOMPLETE: {len(missing)} manifest cases have no verdict "
              f"line; the rate below covers only what ran.")
        for suite, test in missing[:10]:
            print(f"  missing: {suite}/{test}")
        if len(missing) > 10:
            print(f"  ... and {len(missing) - 10} more")
        print()

    total_ok = sum(v[0] for v in by_suite.values())
    total = sum(v[1] for v in by_suite.values())

    print(f"{'suite':<26} {'agree':>6} {'cases':>6}  rate")

    for suite in sorted(by_suite):
        ok, n = by_suite[suite]
        print(f"{suite:<26} {ok:>6} {n:>6}  {100.0 * ok / n:5.1f}%")

    print(f"{'TOTAL':<26} {total_ok:>6} {total:>6}  {100.0 * total_ok / total:5.1f}%")

    missed = sum(1 for d in disagreements if d[2] == "reject")
    wrong = sum(1 for d in disagreements if d[2] == "accept")
    print()
    print(f"{missed} rejected by ponyc and accepted here (a check not implemented)")
    print(f"{wrong} accepted by ponyc and rejected here (a rule got wrong)")

    if missing:
        return 2

    if "--list" in flags:
        print()
        print("disagreements:")

        for suite, test, expect, ours, cpass, message in disagreements:
            note = f": {message}" if message else ""
            print(f"  {suite}.{test}: ponyc {expect}, ponyq {ours} (pass {cpass}){note}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
