#!/usr/bin/env python3
"""Compare diagnostic positions against ponyc across the corpus.

For every valid reject case, this runs ponyc at the earliest erroring
pass `reach.tsv` records and the checker on the same package, and pairs
their diagnostics by message text. A message both emit must sit at the
same line and column: the checker's tree positions a constructed node
at its first child where ponyc's AST positions it at the token that
formed it, and that class of drift is invisible to a verdict — this is
the oracle that sees it.

Only shared messages are compared. A message one side emits and the
other does not is a rule or wording gap, which the corpus and probe
gates own; a position mismatch on a shared message is always a defect
here.

Usage: column_oracle.py <corpus-dir> <checker> <search-root>
"""

import os
import re
import subprocess
import sys
import tempfile

DIAG = re.compile(r"^([^\s:][^:]*):(\d+):(\d+): (.*)$")


def diagnostics(stderr, case):
    """(path-under-case, line, col, message) per located diagnostic.

    Source echoes, carets, headings and indented Info blocks do not
    match the anchored pattern. Paths are cut down to their tail under
    the case directory, because the checker prints canonical absolute
    paths where ponyc prints them as given.
    """
    case = os.path.abspath(case)
    out = []
    for line in stderr.splitlines():
        m = DIAG.match(line)
        if not m:
            continue
        path = os.path.abspath(m.group(1))
        if path.startswith(case + os.sep):
            path = path[len(case) + 1:]
        else:
            path = os.path.basename(path)
        out.append((path, int(m.group(2)), int(m.group(3)), m.group(4)))
    return out


def run(argv):
    try:
        done = subprocess.run(
            argv, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            timeout=120)
    except subprocess.TimeoutExpired:
        return None
    return done.stderr.decode("utf8", "replace")


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 1
    corpus, checker, root = sys.argv[1], sys.argv[2], sys.argv[3]

    cases = {}
    for line in open(os.path.join(corpus, "manifest.tsv"), encoding="utf8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 5:
            cases[(parts[0], parts[1])] = parts[4]

    rejects = []
    for line in open(os.path.join(corpus, "reach.tsv"), encoding="utf8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 8:
            print("the reach file is not in pass_reach.py's eight-column "
                  "format; rerun 'make pass-reach'")
            return 1
        if parts[2] == "reject":
            rejects.append(((parts[0], parts[1]), parts[5]))

    compared = 0
    shared = 0
    mismatches = []
    with tempfile.TemporaryDirectory() as out_dir:
        for i, (key, earliest) in enumerate(rejects):
            case = cases.get(key)
            if case is None:
                continue
            ponyc_err = run(
                ["ponyc", "--pass=" + earliest, "--verbose=0",
                 "-o", out_dir, case])
            ours_err = run([checker, case, "--path=" + root])
            if ponyc_err is None or ours_err is None:
                continue
            compared += 1

            theirs = diagnostics(ponyc_err, case)
            mine = diagnostics(ours_err, case)
            messages = (
                {m for _, _, _, m in theirs} & {m for _, _, _, m in mine})
            for message in sorted(messages):
                shared += 1
                a = sorted(p for *p, m in theirs if m == message)
                b = sorted(p for *p, m in mine if m == message)
                if a != b:
                    mismatches.append((key, message, a, b))

            if (i % 100) == 0:
                print(f"  {i}/{len(rejects)}", file=sys.stderr)

    print(f"{compared} reject cases compared, "
          f"{shared} shared messages position-checked")
    if mismatches:
        print(f"{len(mismatches)} position mismatches:")
        for (suite, test), message, a, b in mismatches:
            print(f"  {suite}/{test}: {message}")
            print(f"    ponyc   {a}")
            print(f"    checker {b}")
        return 1
    print("every shared message sits where ponyc puts it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
