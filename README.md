# A query-based Pony front end for pony-lsp

`DESIGN.md` is the design this implements and the reasoning behind it. It
answers the five questions in `QUERY_BRIEF.md`.

## What is here

| | |
|---|---|
| `pony_syntax` | A lossless, error-tolerant Pony lexer and parser. Every byte of the input is in the tree, nothing fails to produce one, and elements carry widths rather than offsets so an edit changes only what contains it. |
| `pony_analysis` | What a language server asks for, projected from a tree: an outline, foldable regions, selection ranges and syntax diagnostics. No compile, no workspace, nothing on disk. |
| `upstream/` | A working copy of pony-lsp and the `pony_compiler` bridge, vendored unmodified so changes can be made here and applied in one go. See `upstream/UPSTREAM.md`. |
| `tools/agreement` | Whole-corpus checks against ponyc itself. |
| `tools/gen_token_kinds.py` | Generates the token kinds from ponyc's lexer tables. |
| `itemparse/` | A measurement, kept as evidence. See `DESIGN.md` question 3. |

## Building

Needs a ponyc checkout with `build/release` built, for its standard library
and for `libponyc-standalone`:

    make PONYC_ROOT=/path/to/ponyc test

`make corpus` runs the checks against ponyc's own standard library.

## Where it stands

The parser agrees with ponyc's lexer on all 255 files of the standard
library, parses every one of them with no diagnostic, and reprints each byte
for byte from its tree. The analysis layer projects 9267 declarations from
them without a gap.

All four syntax features -- outline, folding, selection and syntax
diagnostics -- answer from the buffer, so they work on an unsaved file and on
one that does not compile. The other twelve still answer from the last
compile, and now say so: a position drawn from it is refused once the buffer
has moved, hover keeps its content and drops its range, and a rename refuses
while any open document has unsaved changes.

342 tests pass, against the 332 the vendored copy started with.
