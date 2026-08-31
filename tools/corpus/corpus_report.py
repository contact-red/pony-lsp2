#!/usr/bin/env python3
"""Compare the checker's accept/reject verdict against ponyc's on the corpus.

Reads the manifest written by extract_corpus.py and the verdicts written
by `checker --batch`, one tab-separated `<dir>` and `(ok|fail|load-failed)`
per line,
and reports the agreement rate per suite.

--reach=reach.tsv restricts scoring to the cases standalone ponyc
validates and flips pass-limited accepts: reach.tsv marks accepts that
full ponyc rejects, and a checker rejecting one of those agrees with
ponyc, not with the case's pass-limited contract. The scored rate is
relative to that universe and is not comparable to a rate over the raw
manifest. reach.tsv's columns are documented in pass_reach.py, which
writes it; every scored case must appear in it, so a reach file older
than the manifest fails the report instead of silently shrinking the
universe.

A `load-failed` verdict is never agreement: it means the checker could
not load the case at all, so any non-zero count fails the report, the
same way a verdict file truncated by a crash does.

Usage: corpus_report.py <manifest.tsv> <verdicts.tsv>
         [--reach=reach.tsv] [--suites=a,b,c] [--list]
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
    invalid = set()
    reject_pass = {}

    for f in flags:
        if f.startswith("--suites="):
            only = set(f.split("=", 1)[1].split(","))
        if f.startswith("--reach="):
            universe = set()
            for line in open(f.split("=", 1)[1], encoding="utf8"):
                parts = line.rstrip("\n").split("\t")
                if not parts or parts == [""]:
                    continue
                if len(parts) != 8:
                    print("the reach file is not in pass_reach.py's "
                          "eight-column format; rerun 'make pass-reach'")
                    return 2
                key = (parts[0], parts[1])
                if parts[2] == "invalid":
                    # Standalone ponyc disagrees with the case's own
                    # assertion; excluded from scoring but recorded so a
                    # stale reach file is distinguishable from one that
                    # excluded the case on purpose.
                    invalid.add(key)
                    continue
                universe.add(key)
                if parts[2] == "accept" and parts[4] == "limited":
                    limited.add(key)
                if parts[2] == "reject":
                    reject_pass[key] = parts[5]

    verdicts = {}

    for line in open(args[1], encoding="utf8"):
        parts = line.rstrip("\n").split("\t")

        if len(parts) >= 2:
            verdicts[parts[0]] = parts[1]

    by_suite = collections.defaultdict(lambda: [0, 0])
    agreed_pass = collections.Counter()
    agreed_accepts = 0
    disagreements = []
    missing = []
    load_failed = []
    unreached = []

    for line in open(args[0], encoding="utf8"):
        parts = line.rstrip("\n").split("\t")
        suite, test, expect, cpass, path = parts[:5]
        message = parts[5] if len(parts) > 5 else ""

        if only is not None and suite not in only:
            continue

        key = (suite, test)
        got = verdicts.get(path)

        if universe is not None and key not in universe:
            # Either excluded as invalid, or the reach file predates
            # this manifest row. A case with a verdict but no reach
            # record is the stale-file signature.
            if got is not None and key not in invalid:
                unreached.append(key)
            continue

        if got is None:
            missing.append(key)
            continue

        if got == "load-failed":
            load_failed.append(key)
            by_suite[suite][1] += 1
            continue

        if key in limited:
            expect = "reject"

        ours = "accept" if got == "ok" else "reject"
        by_suite[suite][1] += 1

        if ours == expect:
            by_suite[suite][0] += 1
            if expect == "accept":
                agreed_accepts += 1
            elif key in limited:
                # A flipped pass-limited accept has no erroring pass;
                # crediting the case's target pass would book it to a
                # slice ponyc never rejected it in.
                agreed_pass["(limited accepts)"] += 1
            else:
                agreed_pass[reject_pass.get(key, cpass)] += 1
        else:
            disagreements.append((suite, test, expect, ours, cpass, message))

    # A verdict file that stops early -- a mid-batch crash -- must fail
    # loudly, not yield an agreement rate over the surviving prefix.
    failures = []
    if missing:
        failures.append(f"{len(missing)} manifest cases have no verdict line")
        for suite, test in missing[:10]:
            print(f"  missing: {suite}/{test}")
    if load_failed:
        failures.append(f"{len(load_failed)} cases failed to load")
        for suite, test in load_failed[:10]:
            print(f"  load-failed: {suite}/{test}")
    if unreached:
        failures.append(
            f"{len(unreached)} verdict cases are absent from the reach "
            f"file; rerun 'make pass-reach'")
        for suite, test in unreached[:10]:
            print(f"  unreached: {suite}/{test}")
    if failures:
        print("INCOMPLETE: " + "; ".join(failures) + ".")
        print()

    total_ok = sum(v[0] for v in by_suite.values())
    total = sum(v[1] for v in by_suite.values())

    if total == 0:
        print("no cases scored: the manifest and verdict file do not "
              "overlap")
        return 2

    print(f"{'suite':<26} {'agree':>6} {'cases':>6}  rate")

    for suite in sorted(by_suite):
        ok, n = by_suite[suite]
        print(f"{suite:<26} {ok:>6} {n:>6}  {100.0 * ok / n:5.1f}%")

    print(f"{'TOTAL':<26} {total_ok:>6} {total:>6}  "
          f"{100.0 * total_ok / total:5.1f}%")

    if universe is not None:
        # Where the agreement comes from, by the earliest pass at which
        # ponyc rejects the case, so an agreement outside the slice
        # being measured shows up as its own row instead of inside the
        # headline.
        print()
        print(f"agreed accepts: {agreed_accepts}")
        print("agreed rejects by ponyc's earliest erroring pass:")
        for cpass, n in agreed_pass.most_common():
            print(f"  {cpass:<22} {n:>5}")

    missed = sum(1 for d in disagreements if d[2] == "reject")
    wrong = sum(1 for d in disagreements if d[2] == "accept")
    print()
    print(f"{missed} rejected by ponyc and accepted here "
          f"(a check not implemented)")
    print(f"{wrong} accepted by ponyc and rejected here (a rule got wrong)")

    if "--list" in flags:
        print()
        print("disagreements:")

        for suite, test, expect, ours, cpass, message in disagreements:
            note = f": {message}" if message else ""
            print(f"  {suite}.{test}: ponyc {expect}, checker {ours} "
                  f"(pass {cpass}){note}")

    if wrong:
        # A false rejection is the failure the floor framing exists to
        # price; the gate fails on the first one.
        for suite, test, expect, ours, cpass, message in disagreements:
            if expect == "accept":
                print(f"  wrong: {suite}/{test}")
        return 2

    if failures:
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
