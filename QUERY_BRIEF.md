# Brief: a query-based Pony front end, in Pony, for pony-lsp

I want to replace pony-lsp's whole-program compile with an incremental,
query-based front end written as a Pony package. Before any code, I want the
design settled and written down.

## What exists

**1. The proof of concept.** `~/projects/test_compiler_ideas` is `ponyq`: a
Rust + salsa query-based Pony front end, ~12.9k lines, checking the standard
library. `FINDINGS.md` is the real output — read it before anything else,
particularly:

- "What this architecture is" — the model in one section
- "Incremental re-checking" — what an edit costs
- "Parallel scaling" and everything under it — what the ceiling is and why
- "What to build, if this were built for real" — the recommendation and the
  open questions
- "The fork" — batch compiler versus language server, and which one keeps the
  memoization

**2. The LSP.** `~/projects/ponylang/ponyc/tools/pony-lsp`, ~3.3k lines plus
tests. It compiles through libponyc.

**3. The bridge it compiles through.**
`~/projects/ponylang/ponyc/tools/lib/ponylang/pony_compiler` — FFI wrappers
over libponyc's `program_load`, `ast_t`, passes and errors.

The seam between 2 and 3 is small and clean, which is the good news:

- `trait tag LspCompiler` with `be compile(package, paths, notify)`
- `interface CompilerNotify` with
  `be done_compiling(package, result: (Program val | Array[Error val] val), run)`
- `actor PonyCompiler` implements `LspCompiler` by calling
  `Compiler.compile(...)` up to `PassFinaliser` and handing back a `Program val`

`Program val` is a libponyc AST with types attached to nodes.
`symbols.pony`, `definition_resolver.pony` and `ast_source_span.pony` all
walk it. Also worth noting: `textDocument/didChange` is not handled at all.
The LSP compiles on open and on save only, which I read as a consequence of
how expensive a compile is.

## Findings that constrain this

These are measured, not guessed, and `FINDINGS.md` has the method behind each
one. They were taken in Rust against salsa, so they do not all travel. The
first four count work in Pony's own dependency graph and should hold; the two
after them are about Rust's memory model, and the text says so where they
appear.

- **The incremental win is real and large.** Re-check after no edit: 0
  queries. After a `//` comment: 1 query out of 20937. After one method body
  in `collections/list.pony`: 1706, or 8.1%.
- **File-level granularity is the limiting flaw.** `parse(file)` returns one
  arena and every node id shifts when the file changes, so an edit to one body
  in `builtin/array.pony` re-runs 33% of a cold check. The fix is an item tree
  addressed by name path rather than by arena index. Assume this is in the
  design from the start, not retrofitted.
- **Node identity by position costs three ways**: 1082246 `ast_of` calls and
  243357 interned keys per check, plus the invalidation problem above.
- **Sharing nothing costs 2.25x in recompute.** Independent workers with
  private memo tables duplicate that much work on the standard library. This
  is a property of the dependency graph rather than of the language, so
  assume it holds here too.

Two more `ponyq` results are about Rust and salsa rather than about the query
model, and they should not be carried over without being re-measured:

- **The 7x parallel ceiling comes from a shared *mutable* interning table.**
  Every lookup takes a shard lock and stores to a line other cores hold, so an
  interned read is a write. That is how salsa implements interning, not
  something the model requires, and Pony has no such failure mode: a `val`
  table is read with no lock and no store. What replaces the cost - an actor
  round trip on a miss, a stale snapshot, or duplicated interning - is
  unmeasured.
- **The persistent-map result was measured against a baseline Pony does not
  have.** A HAMT read path served 77% of interning calls with no lock and was
  still 38% slower on one thread. Half of that was `im` reference-counting
  every node with an `Arc`, which a traced `val` does not pay per access. The
  other half was pointer depth, and it was compared against a lock-protected
  flat table - which does not exist in Pony, where the alternative is a
  message to whichever actor owns the table. Four or five dereferences beat a
  send and a causal wait, so the same design may well win here for the reason
  it lost there.

## What I want settled first

Do not start writing the front end. Work these out and write them up, and
raise anything else you find that belongs on the list.

**1. The output boundary — the decision everything else hangs off.** A query
engine answers questions on demand; it does not produce a whole typed AST.
The LSP's features walk one. So either the feature layer is rewritten to ask
questions (hover asks for a type at a position, definition asks for a
binding), or the new package materialises something `Program`-shaped and the
incrementality stops at the boundary. Give me the options with what each costs
in rewritten LSP code, and a recommendation.

**2. What plays salsa's part, and what it costs in Pony.** Interning,
memoization on interned keys, revision-based invalidation, dependency
tracking, and cycle handling with initial values. There is no salsa in Pony,
so this is its own library with its own design. Tell me what the minimum is
that supports the LSP case, whether it is a separate package from the front
end, and how the memo store is held.

The memo store is the part where none of the Rust measurements decide it.
`val` plus actors is the only route available, which rules out the contention
that caps `ponyq` and puts a different cost in its place. An actor owning the
table and handing out immutable snapshots extended by structure sharing is the
obvious shape; what I want to know is what a miss against a stale snapshot
costs, whether readers can intern locally and reconcile, and what that does to
the guarantee that two structurally equal types get the same key. Design it
around a measurement you can take early rather than around the Rust numbers.

**3. Whether any of libponyc is kept.** A pure-Pony front end needs its own
lexer and parser. `ponyq` transcribed ponyc's, ~3.3k lines of Rust; the same
transcription into Pony is known-feasible but not small. Say whether you would
transcribe, reuse through FFI, or something else, and what each does to the
no-mutation rule the query model depends on.

**4. The smallest useful increment.** `ponyq` is a front end that does not
implement everything and took 12.9k lines. I want the smallest thing that
beats whole-program compile for a real LSP interaction, shipped and measured,
with the rest written down as future work rather than built. Propose what that
first slice is and what it would let the LSP do that it cannot do now.

**5. Where the package lives.** Standalone repository, or in
`ponyc/tools/lib`, or somewhere else. Say which and why.

## How to work

- Read before proposing. Do not describe code you have not opened.
- Discuss the design decisions with me rather than picking a path silently.
- Ask before adopting any dependency that is not in the Pony standard library.
- Ask whether existing conventions in pony-lsp and pony_compiler should be
  preserved rather than assuming.
- Be direct about scale and risk. If a slice is a month of work, say so.

## Deliverable for this pass

A design document: the boundary decision with its options and a
recommendation, the engine design, the scope of the first slice, and an
honest account of what is uncertain. No implementation until I have agreed to
it.
