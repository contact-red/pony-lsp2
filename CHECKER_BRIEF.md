# Brief: a query-based Pony front end, checked against ponyc

`QUERY_BRIEF.md` asked for a front end that made pony-lsp better. That was
the wrong target and it shaped everything under it. This brief replaces it.

The new target is ponyq's: point a binary at a package, have it check the
package and everything the package `use`s, and have it exit clean or print
the errors and exit 255. An editor cannot tell you whether a front end is
right. A corpus can.

## Why the target is changing

pony-lsp lets a front end look finished while its middle is missing. Four
features answer from the buffer today and they answer well, but they are the
four that need nothing but syntax. Everything that needs a type still runs
through libponyc, on a whole-program compile triggered by opening or saving a
file, serialised through one actor because libponyc is not thread-safe. Type
checking is 83% of that compile: 1.53s for `collections`, 6.15s for `stdlib`.

Nothing in the work so far is wrong. The parser is validated more thoroughly
than I expected to get. But the goal selected for breadth — sixteen features,
a policy for each — and the depth was never reached, and with the LSP as the
measure it could go on not being reached indefinitely.

A batch checker cannot do that. It either accepts the standard library or it
does not.

## What exists, and what you may take on trust

Four packages, about 7,100 lines, under
`upstream/tools/lib/ponylang/`. Each claim below is what a check in this
repository reports today; run them rather than believing me, but do not
rebuild what they cover.

**`pony_syntax`** (4,801 lines, of which `token_kind.pony`'s 1,656 are
generated from ponyc's lexer tables). A lossless, error-tolerant lexer and
parser. `make corpus` lexes every Pony file in the ponyc tree and compares
the token sequence against ponyc's own: every one agrees. Every one
reprints byte for byte from its tree under a single root. One produces a
diagnostic, and its source is deliberately not valid Pony. `make mutants`
truncates and corrupts those files thousands of ways; every mutant parses to
a single root, reprints byte for byte, and terminates.

**`pony_analysis`** (1,208 lines). Per-document facts projected from a tree:
declarations, `use`s, bindings, foldable regions, diagnostics. Every
declaration in the tree projects with a name and no gap.

**`pony_bind`** (829 lines). Name resolution across a workspace from syntax
alone, with declarations addressed by name path and carrying no span, so an
edit to a body leaves the package index unchanged. `make bind` resolves
every entity in the standard library from its own file back to itself, every
`use` to a package that exists, and every local, parameter, field and type
parameter to itself. None unresolved, none resolving to the wrong file, none
naming a package that is not there.

**`pony_query`** (282 lines). Inputs with revisions, memoized queries,
dependency tracking, backdating. It `use`s no package at all. The backdating
works, and the revision count is how you see it: checking the standard
library advances the engine one revision per file, one per package, and the
one it starts at. Nothing re-ran that did not have to.

`tools/agreement` and `tools/bind_check` are what those claims come from.
Extend them. They are the reason the parser can be trusted, and a check you
add there outlives any unit test.

## What is being abandoned

`DESIGN.md` is the design of the old target and about half of it is now
dead. Read it for the parts that still hold — the tree's shape, the reasons
behind `pony_syntax` and `pony_bind`, the measurements — and treat the
following as withdrawn rather than unimplemented:

- the depth ladder: `Parsed`, `Bound` and `Typed` as states a document is in
- `DocumentAnalysis`, `Reached`, and the rule that a rung must not replace
  what a deeper rung established
- the eighteen-row table of features with a staleness policy each
- per-feature decisions about serving or refusing a stale answer

All of it is bookkeeping for a front end that shares a document with
libponyc: some answers from a compile of older text, some from the buffer,
and a record of which is which. A query database has no such state. You ask,
and there is a memo or there is a computation. Remove libponyc and every
piece of that machinery has nothing left to do.

This matters because the ladder is a phase model, and phases are what the
architecture is supposed to be free of.

## What ponyq is, and what it cost

`~/projects/test_compiler_ideas` is the Rust proof of concept. `FINDINGS.md`
is the honest account of it; read it before proposing anything.

Its 12,875 lines fall out by layer as:

| Layer | Lines |
|---|---|
| Lexing | 1,436 |
| Parsing and the AST arena | 2,216 |
| Query engine and package loading | 348 |
| Name resolution | 492 |
| Type IR, interning, reification | 217 |
| Signatures — names, sugar, flatten | 1,031 |
| Capability algebra | 427 |
| Subtyping, viewpoint, type-parameter bounds | 1,950 |
| Method bodies | 3,219 |
| Check driver | 290 |
| S-expression printing, for diffing against ponyc | 308 |
| CLI and measurement harness | 941 |

The first four rows have counterparts here, with one gap: the package
loading inside row three is not built, and the next section says so. The six
rows after them — 7,134 lines, 55% of ponyq — have nothing at all.

Read that number with what it bought, and against what it started from.
Those 7,134 lines reach 49.5% agreement with ponyc over ponyc's own unit
tests: 637 of 1288 cases, with 175 more skipped as not a plain verdict on a
single source. The disagreements run 552 "ponyc rejects, ponyq accepts"
against 99 "ponyq got a rule wrong", so most of the gap is checks never
written.

But agreement counts the cases ponyc accepts, and a checker that finds
nothing wrong agrees with every one of them. Measured on this repository's
port of the harness, accepting every program scores about 45%. So 49.5% is
roughly three points above doing nothing at all -- assuming ponyq's corpus
had a similar accept rate, which is unverified. The suites that
test the type system directly do well — subtyping 90.2%, match types 100%,
recursive aliases 97.1%. The ones that test everything else do not: `verify`
32.9% over 280 cases, `badpony` 38.3% over 180.

`FINDINGS.md` names what is hardest, and the first entry is not in the 7,134
at all: ponyc's refer pass tracks whether each name is defined, undefined or
consumed at each point, it is the single biggest block of missing checks,
and it is a dataflow analysis, which does not decompose into queries the way
a syntax-directed rule does.

## The measure of done

**How far agreement with ponyc sits above the floor**, at every stage. Not
agreement itself: a checker that rejects nothing scores about 45% here,
so a bare percentage mostly reports how many programs ponyc accepts. What a
stage is worth is the rejections it adds.

ponyq's harness is ported, in `tools/corpus`. `extract_corpus.py` pulls the
inline sources out of `test/libponyc/*.cc` and `corpus_report.py` compares
verdicts; both are ponyq's, unmodified, because neither mentions Rust or
Pony. The step between them is the binary this brief asks for, and that is
the CLI contract to match. `make corpus-cases` and `make pass-reach` run
what exists.

Two more that already exist here and should keep passing: the standard
library checks clean, and the whole ponyc tree parses.

The binary itself behaves as ponyc does. Exit 0 when there is nothing to
report and 255 when there is. Errors in ponyc's shape — `Error:`, then
`file:line:col: message`, the source line, a caret under the column — with
1-based byte columns, which `LineIndex` produces when given `Utf8`.

## What I want settled before you write the semantic layer

Same contract as last time: work these out, write them up, and raise
anything else that belongs on the list. Do not start on the type checker.

**1. The type IR, and what interning costs in Pony.** ponyq interns types so
that structural equality is an integer compare, and `FINDINGS.md` is direct
that this is the invariant making `is_subtype(a, b)` memoizable on its
arguments at all — the thing ponyc cannot do, which is why it hashes a
structural fingerprint instead. ponyq gets it from a shared mutable table
behind a shard lock, and pays for it: an interned read is a write to a line
other cores hold, and that is where its 6-7x parallel ceiling comes from.
Pony has no such table. Tell me what replaces it, what a miss against a
stale snapshot costs, whether readers can intern locally and reconcile, and
what any of that does to the guarantee that two structurally equal types get
the same key. This is the question `DESIGN.md` left explicitly unmeasured and
it is the one everything else rests on. Design it around a measurement you
can take early.

**2. Where the sugar goes.** ponyc desugars by rewriting the tree, and
ponyq's signature layer reimplements the parts a signature depends on:
default capabilities, default return types, flattened unions and
intersections, nominals resolved to definitions. The tree here is immutable
and lossless and will not be rewritten. Say where sugar lives instead, and
what that does to the rule that a query is a pure function of its inputs.

**3. Cycle handling.** `pony_query` has none, deliberately: `FINDINGS.md`
reports exactly one inherent cycle, `is_subtype` coinduction, and nothing
below subtyping reaches it. Subtyping is the next thing to build, so this
stops being deferrable. Coinductive subtyping falls out of returning `true`
as the initial value, and `FINDINGS.md` calls cycles the piece the query
model fits best. Tell me the minimum that supports it.

**4. Diagnostics that can explain themselves.** A memoized `is_subtype`
returning a `Bool` cannot also return the reason without changing its key or
its result type, and either would wreck the memoization that makes it worth
having. ponyc passes an optional error frame and re-runs with errors
enabled. `FINDINGS.md` says the same trick works and names the cost: the
deciding path and the explaining path are two pieces of code that must agree
and will quietly stop agreeing. Propose something, and if it is ponyc's
trick, say what keeps the two in step.

**5. The first slice.** I want signatures without bodies: everything needed
to say that each declaration's signature is well formed and every type name
in it resolves, checked over the whole standard library, before anything
touches a method body. That is ponyq's type IR, signatures, capability
algebra and enough subtyping, and it leaves out the 3,219-line half. Tell me
whether that is the right cut, what it can and cannot report, and what
agreement percentage it should be expected to reach — a slice that cannot
move the number is the wrong slice.

**6. Whether to fix granularity now.** `FINDINGS.md` names file-level
invalidation as the limiting flaw and name-path addressing as the fix for
both it and interning. `pony_bind` already took the identity half; the
addressing half — item-relative spans, so an edit inside one item leaves
every other item's facts unchanged — is not built. Related: `DocumentFacts`
computes declarations, `use`s, bindings, foldable regions, diagnostics and a
full offset table in its constructor, so one keystroke recomputes all six.
Say whether these are fixed now, when the semantic layer is small, or later
when it is not.

## Two things already known to be missing

Neither is a design question, but do not discover them late.

`Binder.set_package_path` and `Binder.set_builtin` exist and nothing calls
them. Until something does, `use "collections"` resolves to nothing, because
the search paths live inside the compiler actor. Resolution reads
directories, and `pony_bind` touches no disk on purpose — that is what lets
a test drive a whole workspace from string literals — so it belongs
somewhere else. ponyq's `db.rs` is 348 lines and does this; it resolves
against the using package's directory and the roots given on the command
line, and `FINDINGS.md` admits it does not do ponyc's upward
`../pony_packages` search.

`pony-lsp` is not being deleted. It stays vendored under `upstream/` and
keeps working through libponyc while the checker is built. It becomes a
consumer again once there is something to consume, and that is a later
brief, not this one.

## How to work

- Read before proposing. Do not describe code you have not opened.
- Evidence over assertion. Every claim about ponyc or about this repository
  is checkable, so check it. If you cannot, say the claim is unverified.
- Extend the corpus checks rather than writing unit tests that cover cases
  you thought of. Every grammar bug so far was found by the corpus and not
  by a hand-written test.
- Preserve the conventions already here: ~79 columns, `\nodoc\` on test
  declarations, docstrings on public API, `pony_test`.
- Discuss the design decisions with me rather than picking a path silently.
- Ask before adopting any dependency that is not in the standard library.
- Be direct about scale and risk. Say what you do not know.

## Deliverable for this pass

A design document answering the six questions, with the first slice scoped
and an honest account of what is uncertain. No implementation until I have
agreed to it.
