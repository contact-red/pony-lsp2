# Agreement with ponyc's lexer

The unit tests cover cases someone thought of. This covers the ones nobody
did: it lexes every file of a corpus with both `pony_syntax` and ponyc's own
lexer and compares the token kind sequences.

Trivia are excluded, because ponyc's lexer discards them. A boundary error
still shows up, because splitting a token differently changes the sequence.

## Running it

Build both dumpers, then compare:

    ponyc -b dump -o . dump_src

    gcc -O2 -o ponyc_dump ponyc_dump.c -I. \
      -I<ponyc>/src/libponyc -I<ponyc>/src -I<ponyc>/src/common \
      <ponyc>/build/release/libponyc-standalone.a \
      <ponyc>/build/release/libponyrt-pic.a \
      -lstdc++ -lm -lz -lpthread -ldl -latomic

    ./check.py <ponyc>/packages/**/*.pony

`tk_names.h` maps a `token_id` to its enumerator name, which ponyc has no API
for -- `token_id_desc` gives a human description, not a name.

The Pony sources live in `dump_src/` rather than beside `ponyc_dump.c`
because ponyc compiles any C source it finds in a package directory.

## The reprint check

The same binary, with `--reprint`, parses each file instead and reports any
whose tree does not reprint to the source byte for byte, any whose root does
not span every element, and any that produced a diagnostic -- valid Pony
should produce none:

    ./dump --reprint <ponyc>/packages/**/*.pony

Losslessness over real code, rather than over cases someone thought of.

## Result

255 of 255 files in ponyc's `packages/` agree on tokens, and 255 of 255
reprint from their tree with a single root and no diagnostics.

The one disagreement this found and hand-written tests did not: a raw
newline inside a single-quoted string. ponyc's `string` scans to the closing
quote or the end of the source and checks nothing else, and
`files/_non_root_test.pony` relies on it.

The reprint check found what the unit tests did not: leading whitespace or a
leading comment was emitted before the root node rather than inside it,
because `start` flushed pending trivia into the enclosing node and the root
has none. Fourteen files in the standard library begin that way. The unit
test now includes sources that start with trivia.

The diagnostic count is the sharper of the two signals, because it says the
grammar accepted what ponyc accepts rather than merely that no bytes were
lost. It found the two bugs the unit tests did not:

  - The method body skeleton stopped at `var`, `let` and `embed`, which
    start a local declaration. Every body ended at its first local and the
    rest was read as fields -- 115 of the 255 files.
  - `iftype` lexes as `TkIftypeSet`, not `TkIftype`, so the skeleton never
    counted it as opening a region and its `end` looked unbalanced.

## The facts check

`./dump --facts <files>` projects the analysis facts from each file and
reports any declaration with no name, and any file that produced a
diagnostic.

Over ponyc's `packages/`: 255 files, no failures, 9267 declarations of which
1542 are top level.

A grep for lines beginning with an entity keyword finds 1590. The 48
difference is the check working: grep counts `actor Main` at column 0 inside
`String`'s docstring, in a fenced example, and the parser does not.
