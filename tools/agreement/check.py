#!/usr/bin/env python3
"""Compare pony_syntax's lexer against ponyc's over a corpus.

Both dumpers emit one token kind per line, per file, with trivia excluded --
ponyc's lexer discards trivia, so only the tokens both produce are compared.
A boundary error changes the sequence, so this catches mis-splits as well as
mis-classification.

    tools/agreement/check.py <file.pony>...
"""
import subprocess
import sys
import os
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))


def dump(cmd, files, keep=False):
    out = subprocess.run([cmd] + files, capture_output=True, text=True).stdout
    per_file, current = {}, None
    for line in out.splitlines():
        if line.startswith("### "):
            current = line[4:]
            per_file[current] = []
        elif current is not None:
            per_file[current].append(line if keep else line.split("\t")[0])
    return per_file


def main(files):
    theirs = dump(os.path.join(HERE, "ponyc_dump"), files)
    ours = dump(os.path.join(HERE, "dump"), files)

    agree, differ = 0, []
    mismatches = Counter()
    for f in files:
        a, b = theirs.get(f), ours.get(f)
        if a is None or b is None:
            differ.append((f, "one side produced nothing"))
            continue
        if a == b:
            agree += 1
            continue
        for i, (x, y) in enumerate(zip(a, b)):
            if x != y:
                mismatches[(x, y)] += 1
                differ.append((f, "token %d: ponyc %s, ours %s" % (i, x, y)))
                break
        else:
            mismatches[("<length>", "<length>")] += 1
            differ.append((f, "lengths differ: ponyc %d, ours %d"
                           % (len(a), len(b))))

    print("files    : %d" % len(files))
    print("agree    : %d" % agree)
    print("differ   : %d" % len(differ))
    if mismatches:
        print("\nfirst divergence by kind pair, most common first:")
        for (x, y), n in mismatches.most_common(15):
            print("  %5d  ponyc %-22s ours %s" % (n, x, y))
    if differ:
        print("\nexamples:")
        for f, why in differ[:10]:
            print("  %s: %s" % (os.path.relpath(f), why))
    return 1 if differ else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    sys.exit(main(sys.argv[1:]))
