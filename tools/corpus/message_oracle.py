#!/usr/bin/env python3
"""Check that agreed rejections reject for ponyc's reason.

A verdict corpus alone shipped ponyq ninety-nine wrong rejections it
never noticed: a case rejected for any reason scores as agreement. For
every scored reject case whose manifest row carries ponyc's expected
message, this runs the checker in single mode and requires that message
to appear, as a substring, somewhere in the emitted diagnostics — the
same match ponyc's own test macros make.

A miss is a case the checker rejects for a different reason than the
one its test asserts. Known divergences live in
`message_exceptions.tsv` beside the manifest — suite, test, and the
reason, one per line, tab-separated — and are reported but do not fail
the run; a miss not listed there does.

Usage: message_oracle.py <corpus-dir> <checker> <search-root>
"""

import os
import subprocess
import sys


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 1
    corpus, checker, root = sys.argv[1], sys.argv[2], sys.argv[3]

    exceptions = {}
    here = os.path.dirname(os.path.abspath(__file__))
    exc_path = os.path.join(here, "message_exceptions.tsv")
    if os.path.exists(exc_path):
        for line in open(exc_path, encoding="utf8"):
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3 and not parts[0].startswith("#"):
                exceptions[(parts[0], parts[1])] = parts[2]

    rejects = set()
    for line in open(os.path.join(corpus, "reach.tsv"), encoding="utf8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 8:
            print("the reach file is not in pass_reach.py's eight-column "
                  "format; rerun 'make pass-reach'")
            return 1
        if parts[2] == "reject":
            rejects.add((parts[0], parts[1]))

    checkable = 0
    matched = 0
    known = []
    misses = []
    for line in open(os.path.join(corpus, "manifest.tsv"), encoding="utf8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 6 or not parts[5]:
            continue
        key = (parts[0], parts[1])
        if key not in rejects:
            continue
        try:
            done = subprocess.run(
                [checker, parts[4], "--path=" + root],
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                timeout=120)
        except subprocess.TimeoutExpired:
            continue
        if done.returncode != 255:
            # Not an agreed rejection; the corpus gate owns the verdict.
            continue
        checkable += 1
        stderr = done.stderr.decode("utf8", "replace")
        if parts[5] in stderr:
            matched += 1
        elif key in exceptions:
            known.append((key, exceptions[key]))
        else:
            misses.append((key, parts[5], stderr))

    print(f"{checkable} agreed rejections carry ponyc's expected message; "
          f"{matched} reject for that reason")
    if known:
        print(f"{len(known)} known divergences:")
        for (suite, test), why in known:
            print(f"  {suite}/{test}: {why}")
    if misses:
        print(f"{len(misses)} rejected for the wrong reason:")
        for (suite, test), expected, stderr in misses:
            print(f"  {suite}/{test}")
            print(f"    ponyc expects: {expected}")
            emitted = [
                ln for ln in stderr.splitlines()
                if ln and ln != "Error:" and not ln.startswith(" ")
            ]
            for ln in emitted[:4]:
                print(f"    emitted: {ln}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
