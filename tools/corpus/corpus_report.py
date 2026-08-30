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

    for f in flags:
        if f.startswith("--suites="):
            only = set(f.split("=", 1)[1].split(","))

    verdicts = {}

    for line in open(args[1], encoding="utf8"):
        parts = line.rstrip("\n").split("\t")

        if len(parts) == 2:
            verdicts[parts[0]] = parts[1]

    by_suite = collections.defaultdict(lambda: [0, 0])
    disagreements = []

    for line in open(args[0], encoding="utf8"):
        parts = line.rstrip("\n").split("\t")
        suite, test, expect, cpass, path = parts[:5]
        message = parts[5] if len(parts) > 5 else ""

        if only is not None and suite not in only:
            continue

        got = verdicts.get(path)

        if got is None:
            continue

        ours = "accept" if got == "ok" else "reject"
        by_suite[suite][1] += 1

        if ours == expect:
            by_suite[suite][0] += 1
        else:
            disagreements.append((suite, test, expect, ours, cpass, message))

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

    if "--list" in flags:
        print()
        print("disagreements:")

        for suite, test, expect, ours, cpass, message in disagreements:
            note = f": {message}" if message else ""
            print(f"  {suite}.{test}: ponyc {expect}, ponyq {ours} (pass {cpass}){note}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
