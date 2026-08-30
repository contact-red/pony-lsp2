# A query-based Pony front end for pony-lsp

`DESIGN.md` is the design this implements and the reasoning behind it. It
answers the five questions in `QUERY_BRIEF.md`.

## What is here

| | |
|---|---|
| `pony_syntax` | A lossless, error-tolerant Pony lexer and parser. Every byte of the input is in the tree, nothing fails to produce one, and elements carry widths rather than offsets so an edit changes only what contains it. |
| `pony_analysis` | What a language server asks for, projected from a tree: an outline, foldable regions, selection ranges and syntax diagnostics. No compile, no workspace, nothing on disk. |
| `pony_bind` | Which declaration a name refers to, across the files of a workspace, from syntax alone. Declarations are addressed by name path and hold no span, so an edit to a body leaves the workspace index unchanged. |
| `pony_query` | The incremental computation engine: inputs, memoized queries, dependency tracking and backdating. It holds no results -- those live in the caller's own typed tables -- and depends on nothing but `builtin`. Cycle handling waits until subtyping needs it. |
| `upstream/` | A working copy of pony-lsp and the `pony_compiler` bridge, vendored unmodified so changes can be made here and applied in one go. See `upstream/UPSTREAM.md`. |
| `tools/agreement` | Whole-corpus checks against ponyc itself. |
| `tools/bind_check` | Every entity ponyc's standard library declares, resolved from its own file back to itself, every `use` naming a package the workspace has, and every local, parameter, field and type parameter resolving to itself. |
| `tools/memo_bench`, `tools/actor_latency` | The measurement `DESIGN.md` question 2 says to take before committing to a memo store. |
| `tools/gen_token_kinds.py` | Generates the token kinds from ponyc's lexer tables. |
| `itemparse/` | A measurement, kept as evidence. See `DESIGN.md` question 3. |

## Building

Needs a ponyc checkout with `build/release` built, for its standard library
and for `libponyc-standalone`:

    make PONYC_ROOT=/path/to/ponyc test

`make corpus` runs the checks against every Pony file in the ponyc tree.

## Where it stands

The parser agrees with ponyc's lexer on all 986 Pony files in the ponyc
tree and reprints each of them byte for byte from its tree. One produces a
diagnostic, and its source is deliberately not valid Pony. The analysis
layer projects 19144 declarations from them without a gap.

All four syntax features -- outline, folding, selection and syntax
diagnostics -- answer from the buffer, so they work on an unsaved file and on
one that does not compile. So does workspace symbols, and so does go to
definition for locals, parameters, fields, type parameters and the types the
workspace declares. The remaining ten answer from the last compile, and now
say so: a position drawn from it is refused once the buffer has moved, hover
keeps its content and drops its range, and a rename refuses while any open
document has unsaved changes.

343 tests pass, against the 332 the vendored copy started with.
