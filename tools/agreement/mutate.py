#!/usr/bin/env python3
"""
Build a corpus of malformed sources from a corpus of valid ones.

Valid Pony is not the hard case for an error-tolerant parser; a file being
typed is. Each input gives seven truncations -- a file part-written -- and
three deletions and three punctuation insertions each, a file part-edited.

The seed is fixed, so the mutants are the same every run and a failure can
be looked at rather than merely counted.

    ./mutate.py <outdir> <file.pony>...
    ./dump --reprint <outdir>/*.pony
"""

import os
import random
import sys

PUNCTUATION = b'{}()[]|\\<>=?#@~.,;:"\'!$%^&*'


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 1

    out_dir, paths = sys.argv[1], sys.argv[2:]
    os.makedirs(out_dir, exist_ok=True)
    rng = random.Random(20260827)
    written = 0

    for path in paths:
        try:
            source = open(path, 'rb').read()
        except OSError as e:
            print(f'skipping {path}: {e}', file=sys.stderr)
            continue
        if not source:
            continue

        for eighth in range(1, 8):
            cut = len(source) * eighth // 8
            write(out_dir, 't', written, source[:cut])
            written += 1

        for _ in range(3):
            i = rng.randrange(len(source))
            j = min(len(source), i + rng.randrange(1, 40))
            write(out_dir, 'd', written, source[:i] + source[j:])
            written += 1

            junk = bytes(rng.choice(PUNCTUATION)
                         for _ in range(rng.randrange(1, 12)))
            write(out_dir, 'i', written, source[:i] + junk + source[i:])
            written += 1

    print(f'{written} mutants in {out_dir}')
    return 0


def write(out_dir: str, prefix: str, n: int, content: bytes) -> None:
    with open(os.path.join(out_dir, f'{prefix}{n}.pony'), 'wb') as f:
        f.write(content)


if __name__ == '__main__':
    sys.exit(main())
