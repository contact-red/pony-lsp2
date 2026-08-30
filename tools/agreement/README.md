# Agreement with ponyc's lexer

The unit tests cover cases someone thought of. This covers the ones nobody
did: it lexes every file of a corpus with both `pony_syntax` and ponyc's own
lexer and compares the token kind sequences.

Trivia are excluded, because ponyc's lexer discards them. A boundary error
still shows up, because splitting a token differently changes the sequence.

## Running it

    make corpus     # the three checks below, over the whole ponyc tree
    make mutants    # the same losslessness over sources that are not Pony

`make tools` builds the two dumpers on their own. The C one links against
libponyc-standalone, so it needs a built ponyc; `PONYC_ROOT` says where.

`tk_names.h` maps a `token_id` to its enumerator name, which ponyc has no API
for -- `token_id_desc` gives a human description, not a name.

The Pony sources live in `dump_src/` rather than beside `ponyc_dump.c`
because ponyc compiles any C source it finds in a package directory.

## The reprint check

The same binary, with `--reprint`, parses each file instead and reports any
whose tree does not reprint to the source byte for byte and any whose root
does not span every element. It counts the files that produced a diagnostic
separately, because valid Pony should produce none but a mutant should.

Losslessness over real code, rather than over cases someone thought of.

## The tree dump

`./dump --tree <file>` prints the parse tree, one indented line per element
with its offset, width and, for a leaf, its text. What a rule builds can
then be read rather than guessed at, which is how the shapes the expression
rules produce were checked against ponyc's own before they were asserted on.

## Result

`make corpus` runs all three over every Pony file in the ponyc tree, not
just the standard library: its own test fixtures are where the grammar's
edge cases live.

Every file agrees on tokens, and every file reprints from its tree with a
single root. One produces a diagnostic:
`compile_errors_04/main.pony` is the single line `use "unfinished`, a
fixture whose whole purpose is to be unterminated.

The one disagreement this found and hand-written tests did not: a raw
newline inside a single-quoted string. ponyc's `string` scans to the closing
quote or the end of the source and checks nothing else, and
`files/_non_root_test.pony` relies on it.

The reprint check found what the unit tests did not: leading whitespace or a
leading comment was emitted before the root node rather than inside it,
because `start` flushed pending trivia into the enclosing node and the root
has none. `./dump --trivia <files>` reports which files begin that way, so
the shape can be found again rather than argued about. The unit test now
includes sources that start with trivia.

The diagnostic count is the sharper of the two signals, because it says the
grammar accepted what ponyc accepts rather than merely that no bytes were
lost. Every bug in the grammar so far has been found this way and not by a
hand-written test. Before the expression rules existed, method bodies were
consumed as balanced regions, and the count found two bugs in that: the
region stopped at `var`, `let` and `embed`, so every body ended at its first
local declaration and the rest was read as fields; and `iftype` lexes as
`TkIftypeSet`, not `TkIftype`, so its `end` looked unbalanced.

Widening the corpus past `packages/` to the rest of ponyc found the next
two, both in the same two files -- ponyc's own annotation fixtures, which
put `\a, b\` everywhere the grammar allows one. That is the argument for
the wider corpus: 255 files of tidy standard library said nothing about
either.

  - `else`, `then` and the condition after `until` take annotations. ponyc
    reaches all three through `annotatedseq`; reading them as plain
    sequences left nothing able to consume the backslash.
  - Nothing consumed it, so the sequence rule went around again in the same
    place. **The parser hung.** A rule that consumes nothing must not be
    repeated, and the sequence loop now takes such a token as an error.

## The mutation check

Valid Pony is not the hard case for an error-tolerant parser; a file being
typed is. `mutate.py` truncates each source at eighths and deletes and
inserts random runs of punctuation, from a fixed seed so a failure can be
looked at rather than merely counted. `make mutants` builds them and
reprints every one.

Every mutant parses to a single root, reprints byte for byte, and
terminates. Most produce a diagnostic, which is what a malformed source
should do and why the summary counts diagnostics apart from failures.

This is the check the hang above would have failed, and it is worth
re-running whenever a rule gains a loop.

## The facts check

`./dump --facts <files>` projects the analysis facts from each file and
reports any declaration with no name, and any file that produced a
diagnostic.

Over the whole tree every declaration projects with a name, and the only
file reporting a diagnostic is the one whose source is deliberately not
valid Pony.

The counts themselves are not recorded here. They move whenever ponyc's tree
does, so a number written down goes stale without anything being wrong, and
what the check asserts is that nothing is missing rather than how much there
is. The one pair kept below is a measurement of two past states, which does
not drift.

Measured when the expression rules landed, the same check went from 9267 and
1542 to 9630 and 1547. 307 of that difference are members of `object`
literals, which the old balanced-region reading of a body passed over
without seeing; the remainder is not attributed, because the old numbers
cannot be re-derived from the current source.

A grep of `packages/` for lines beginning with an entity keyword finds more
than the parser reports, and the difference is the check working: grep counts
`actor Main` at column 0 inside `String`'s docstring, in a fenced example,
and the parser does not.
