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

## Result

255 of 255 files in ponyc's `packages/` agree.

The one disagreement this found and hand-written tests did not: a raw
newline inside a single-quoted string. ponyc's `string` scans to the closing
quote or the end of the source and checks nothing else, and
`files/_non_root_test.pony` relies on it.
