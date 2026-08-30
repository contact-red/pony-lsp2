# The semantic layer: answers to `CHECKER_BRIEF.md`

Answers the six questions the brief asks before any type checker is written.

Produced by one pass rather than by the design ensemble in
`pony-software-design` — this session had no subagents, so the three design
personas and five evaluation personas did not run. What follows is one
reading, and the evaluation stage that would normally stress it did not
happen. Weigh it accordingly.

Nothing here is implemented. One measurement was taken and is reported below;
everything else is a proposal.

## Divergences

Where this departs from what exists or from what the brief assumes.

**`pony_query` gains cycle handling now, not later.** The brief lists it as
question 3 and `DESIGN.md` deferred it until subtyping needed it. Subtyping is
the first slice, so it is needed at the start rather than at the end.

**Type identity does not use the engine's memo store.** `DESIGN.md` chose a
persistent map published from one actor, measured. That decision stands for
memoized *results*. Type identity is proposed as content-addressed instead,
which means there is no interning table at all — a different mechanism, not a
different tuning of the same one.

**`DocumentFacts` is split.** It currently computes six projections in one
constructor. Question 6 proposes splitting it, which changes a public
constructor in `pony_analysis`.

**The brief's "number to beat" is the wrong measure.** It names ponyq's 49.5%
agreement as the target. Agreement counts the cases ponyc *accepts*, and a
checker that finds nothing wrong agrees with all of them, so the floor is
46.1% before a single rule is written. Question 5 has the measurement. What a
slice is worth is its distance above that floor, not its agreement.

## What was measured

`tools/type_hash`, `make types`. The fourth measurement `DESIGN.md` listed and
never took: what content-addressed type identity costs.

10,000 types at depth 4 with up to 3 type arguments, walked with a prime
stride so the access pattern is not sequential. Five runs, because a single
run moves by more than the deviation `pony_bench` reports for it.

| | median | across five runs |
|---|---|---|
| harness — two array reads, subtract this | 33 ns | 33-34 |
| build a type, folding children's cached digests | 344 ns | 326-346 |
| build a type, hashing the whole subtree | 930 ns | 929-948 |
| look a digest up in a persistent table | 532 ns | 498-550 |
| decide equality by comparing digests | 203 ns | 201-211 |
| decide equality by walking both types | 463 ns | 417-486 |

Read the ratios, not the magnitudes: every row above the harness pays two
dependent pointer chases into a 10,000-object heap, and that dominates the
absolute numbers.

Three results, on medians with the harness subtracted. Caching the digest in
the value makes construction **2.9x** cheaper than recomputing it from the
subtree — 311 ns against 897 ns — so `DESIGN.md`'s "bottom-up, cacheable in
the value, so O(1) amortised" holds. Digest equality is **2.5x** cheaper than
structural equality, 170 ns against 430 ns, and the gap widens with type
depth. And a table lookup costs **1.6x** the entire fold that replaces it,
499 ns against 311 ns, before any coordination cost — ponyq additionally pays
a shard lock here that a Pony `val` snapshot would not.

## Question 1 — the type IR, and identity

### The IR

Start from `hir.rs` rather than inventing one. It is 217 lines, it checks the
standard library, and four of its decisions are load-bearing in ways that are
not obvious from the shape:

- **Aliases are kept unexpanded.** Expanding at lowering does not terminate,
  because an alias may refer to itself through a nominal's type arguments and
  ponyc's typealias-recursion pass permits that.
- **A type-parameter reference stores the capability as *written*, not the
  one its constraint implies.** `FINDINGS.md` reports this as the fix that
  removed a cycle: computing the effective capability during lowering made
  `lower_type` and `typeparam_constraint_of` mutually recursive. The effective
  capability is resolved where it is used instead.
- **A lambda type stays a type.** ponyc desugars `{(A): B}` into an anonymous
  interface added to the module — a tree mutation that has to invent a name.
  Here it is structural, and subtyping treats it as an interface with one
  `apply`.
- **There is an `Error` type that is a subtype and supertype of nothing.** One
  bad type does not cascade into every expression that touches it.

The Pony shape is a union, so the compiler can check a match is exhaustive:

```pony
type Ty is
  ( Nominal | AliasRef | TypeParamRef | Union | Isect | Tuple | Arrow
  | LambdaTy | CapType | IntLit | FloatLit | ThisType | DontCare | ErrorTy )
```

`IntLit` and `FloatLit` are separate from any concrete numeric type on
purpose. ponyc calls them `TK_LITERAL`, and a literal that never meets a
context is an error rather than a default — collapsing them into `I64` would
make that error unrepresentable.

### Identity

`is_subtype(a, b)` is memoizable on its arguments only if two structurally
equal types are the same key. That is the invariant the whole layer rests on,
and `FINDINGS.md` says so plainly: it is what ponyc cannot do, which is why
`subtype_cache.c` hashes a structural fingerprint instead.

ponyq gets it from a central mutable table — intern, receive a counter — and
pays for it with the shard lock that is the whole of its 6-7x parallel
ceiling. Pony cannot build that design, so the question is open rather than
inherited.

**Take `DESIGN.md`'s candidate D: a type's identity is a 128-bit structural
digest, folded from its children's digests when it is constructed.** There is
no interning table, no allocator, and no coordination. Two actors that build
the same type derive the same identity without communicating, because the
identity is a function of the structure and nothing else.

The measurement says this is cheaper than the table it replaces, but cost is
not the argument. The argument is that interning stops being a coordination
mechanism. Under a central table, "two structurally equal types get the same
key" is a property maintained by a protocol; under a digest it is a property
of arithmetic. `DESIGN.md` reached the same conclusion from correctness alone
and said it should be preferred before performance is considered — the
measurement now says performance agrees rather than being a price.

Storage deduplication is then a separate, optional, local concern. A worker
may keep a map from digest to `Ty` to avoid rebuilding equal types; it may
skip it, and nothing breaks except memory.

### The collision, stated

A 128-bit digest collision makes two different types one type, silently, and
produces a wrong answer with no error. That has to be written down rather than
waved at.

At ponyq's measured 243,357 interned keys per check, the birthday probability
is about `n²/2^129`, or 9 x 10^-29. It will not happen. But "will not happen"
is a probability, not a guarantee, so the design should not depend on the
digest alone where it is cheap not to.

**Verify structurally on insert into a deduplication map, never on read.** A
map from digest to `Ty` is the only place two distinct types can be conflated,
and it is entered once per distinct type rather than once per comparison. The
measured structural walk is 430 ns — paid on insert, it is invisible; paid on
every equality test, it would defeat the purpose. A worker that keeps no map
does no verification and accepts the bound, which is the honest trade and
should be documented at the type rather than assumed.

## Question 2 — where the sugar goes

ponyc rewrites the tree. `a + b` becomes a call to `add`, a `for` becomes a
while over an iterator, a concrete type with no constructor gets a `create`, a
primitive gets `eq` and `ne`. The tree here is immutable and lossless and will
not be rewritten, which is the same constraint ponyq had, and its split is the
right one:

**Sugar that only affects checking is applied on the way past.** The checker
types `a + b` as the call it stands for and a `for` loop as the iterator
protocol it stands for, without materialising either. Nothing is written back
and no query result records the desugared form.

**Sugar that changes what a signature contains lives in the signature
queries**, because subtyping depends on it. `method_table(entity)` synthesises
the default `create`, a primitive's `eq` and `ne`, and default return types.

This costs nothing in purity: synthesis is a pure function of the definition,
so `method_table` is a query like any other, and its result is a value that
compares equal when the definition has not changed.

It costs something in visibility, and that is the part to plan for. **The
order of synthetic members is semantically load-bearing and stops being
visible.** ponyc adds a primitive's `eq` *after* the traits pass has copied in
what it inherits, so an inherited `eq` wins; ponyq got this backwards and
`primitive Less is Equatable[Compare]` failed. In a pass pipeline that
ordering is a line in the pass list. In a set of queries it is a line inside
one function, and nothing enforces it.

So: `method_table` gets a test asserting the inherited-wins case directly, on
`Less is Equatable[Compare]`, rather than relying on a corpus run to catch a
regression at a distance.

## Question 3 — cycle handling

### What the engine does today

Nothing, and it does not fail safely. `Engine._bring_current` recurses into
dependencies and `_run` calls `runner.run`, which calls `demand`, which
re-enters `_bring_current`. A query that reaches itself recurses until the
stack ends. There is no in-progress state to detect it with.

The engine's own docstring already flags a related unknown: the descent "is
bounded by the stack rather than by anything the engine controls. Nothing
measured yet says how deep a real dependency chain gets."

### The minimum

Two additions.

**An in-progress mark per query, and a caller-supplied initial value.** When
`demand` reaches a query already being computed, it does not recurse — it
returns, and the caller reads whatever initial value the query kind supplies.
For `is_subtype` that value is `true`, and coinductive subtyping falls out of
it. `FINDINGS.md` calls cycles "the piece the model fits best" and reports
this as one line replacing ponyc's per-thread assumption stack.

**Memoizing the coinductive result is sound here and is not sound in ponyc.**
ponyc's `is_x_sub_x` clears its cache at every depth-0 entry, because a
conditional entry is only valid while the frame that created it is live, and
because a freed AST's address can be reused. Neither hazard exists with
content-addressed identity: a digest is stable and a memo is keyed on values.
So the result is shared across top-level calls, which ponyc cannot do — it
rediscovers `Array[A] <: Seq[A]` on every call.

**Fixpoint iteration is not needed yet.** Of the five cycles `FINDINGS.md`
records, one is inherent and reached constantly, one was removed by not
computing a value too early, and three are defensive and the standard library
reaches none. Build the initial-value re-entry now and add iteration when a
query needs it.

### The one thing that cannot be a query

ponyc carries a *divergence* guard, not a cycle guard: on recursive generic
interfaces each level has the same definitions but strictly larger type
arguments, so no pair repeats and coinduction never fires. ponyc counts
same-definition frames and bails after four.

That cannot be expressed. It is a function of the call stack, and a memoized
query may depend only on its key — a result computed under a stack-dependent
bound would be memoized and reused where the bound did not apply. ponyc has
the same problem and solves it by poisoning the cache entry.

Bound on the structural depth of the two types instead, which *is* a function
of the key, so the memo stays sound. It is not ponyc's rule and will disagree
on deeply nested inputs. The corpus will say how many.

### The lesson worth carrying

`FINDINGS.md` states it and it generalises past its instance: **a cycle in a
query graph is sometimes a report that a value is being computed too early.**
Two of ponyq's five cycles were this, and both were removed by asking for a
piece of a definition rather than for the definition's signature. Every pass
boundary in ponyc is worth reading as a possible instance.

## Question 4 — diagnostics that can explain themselves

Split the problem, because it is two problems wearing one name.

**A query that returns a value carries its diagnostics as a field.** This is
most of them. `body_types(method)` returns the type of every node plus that
body's diagnostics; `method_table` returns members plus what was wrong with
them. salsa needs accumulators because a query whose result is interned cannot
also carry a list; a Pony query returning a plain `val` struct has no such
limit. `DESIGN.md` reached this already.

**`is_subtype` is the hard case and it is the only one.** It returns `Bool`.
Adding a reason changes the result type, which changes what is memoized, which
destroys the sharing that makes it worth memoizing — and it is called on the
order of a hundred thousand times per check.

ponyc's answer is a second path: re-run with an error frame when an
explanation is needed. `FINDINGS.md` says the trick works here too and names
the cost precisely — the deciding code and the explaining code are two paths
that must agree and will quietly stop agreeing.

**Take the two paths, and make the agreement checkable rather than
aspirational.** `is_subtype` stays `Bool` and memoized. `explain_subtype` is
unmemoized, walks the same rules, and returns a reason. The invariant is that
one returns `false` exactly when the other returns a reason.

That invariant is testable in the harness that already exists: a corpus mode
that calls the explainer on every rejection the checker makes and fails when
it produces no reason. Every one of ponyq's grammar bugs was found by the
corpus rather than by a hand-written test, and this is the same shape of
problem — a divergence that appears on inputs nobody thought to write down.

The residual risk is the other direction: the explainer producing a reason
where the checker accepted. Checking that costs a full explainer run on every
accepted pair, which is too expensive to leave on. Run it as a corpus mode, not
in the checker.

## Question 5 — the first slice

The brief proposes signatures without bodies and asks whether that is the
right cut, what it can report, and what agreement it should reach. The last
question is the one that matters and the answer is uncomfortable.

### What it is

Everything needed to say that each declaration's signature is well formed and
every type name in it resolves: the type IR, lowering, the capability algebra,
`method_table` with its synthesised members, reification, and enough subtyping
to check that a class provides what it claims. ponyq's counterparts are 217 +
1,031 + 427 + 1,950 lines, and it leaves out the 3,219-line half.

### What it can and cannot report

It can report an unresolved type name, a wrong type-argument count, a
constraint a type argument does not satisfy, a capability that is not legal
where it is written, and a class that does not provide what its `provides`
list claims. Every one of those is a real ponyc error and none needs a body.

It cannot report anything inside a method body, which is where most of a
compiler's errors live.

### What agreement it reaches, measured

`tools/corpus` is ponyq's harness, ported. `extract_corpus.py` writes each
`TEST_F` in ponyc's `test/libponyc/*.cc` out as a package with the verdict its
macro asserts — 1,416 cases, 183 skipped as not a plain verdict on one source.

`pass_reach.py` settles what this slice can reach without having to build it.
Everything the slice does happens at or before ponyc's `traits` pass, and body
checking is `expr`, so running each case with ponyc stopped after `traits`
says which rejections need a body and which do not.

Over the 1,174 cases whose own suite runs `traits` at all — 242 stop earlier,
and for those ponyc never runs the passes being compared, so they are
excluded:

| | cases |
|---|---|
| ponyc accepts, nothing wrong by `traits` | 538 |
| ponyc accepts, error by `traits` | 3 |
| ponyc rejects, error by `traits` — reachable without bodies | 99 |
| ponyc rejects, nothing wrong by `traits` — needs a body | 534 |

**The ceiling is 637 of 1,174, or 54.3%**, assuming the slice makes no false
rejection. My earlier estimate of 9% was wrong, and wrong in method rather
than in magnitude: it counted suites a signature checker could contribute to
and forgot that agreement counts the accepted cases too.

**Accepting every program scores 46.1%.** That is the floor any agreement
figure sits on, and it is what makes the brief's framing misleading. The
slice's 99 reachable rejections are worth **8.2 points** over a checker that
does nothing at all.

It reframes ponyq too. Its 49.5% is about three points above the same floor:
if its corpus had a similar accept rate, its 99 wrong rejections very nearly
cancelled its correct ones, and 12.9k lines bought a small margin over
accepting everything. That arithmetic assumes ponyq's accept rate matches this
corpus's, which I have not verified.

So the slice is worth building, on a better argument than I had: its ceiling
is above what ponyq measured, not far below it. Two reasons stand independent
of the number. Bodies cannot be built first — `body_types` reads signatures
and `FINDINGS.md`'s central claim is that it reads nothing else, so signatures
are the only layer with no dependency above it. And the harness, the CLI
contract and the exit codes have to exist before any number can move at all;
they now do.

## Question 6 — granularity

**Fix it now.**

`FINDINGS.md` names file-level invalidation as the limiting flaw and measures
it: editing one method body in `list.pony` re-ran 1,706 queries, 160 of them
`body_types` — one for every method in the file rather than one for the method
edited. In `builtin/array.pony` the same edit costs 33% of a cold check. The
mechanism is precise and is not coarse dependency tracking: `parse(file)`
returns one arena and every node id shifts when the file changes, so a query
keyed on "node 8237" is keyed on something the edit moved.

There are two reasons to do it before the semantic layer rather than after.

**The semantic layer is what makes it expensive.** Today the numbers are
small: `pony_bind` already keys declarations by name path and holds no spans,
so a body edit leaves the package index untouched. Once signatures are keyed
by node index, every signature in a file re-lowers on any edit to it, and
every memo above them falls over. Retrofitting means re-keying every semantic
query that exists by then.

**`pony_bind` already took half the fix.** `BoundItem` carries a name path and
no span, deliberately. The missing half is item-relative spans, so that an
edit inside one item leaves every other item's facts bit-identical.
`DESIGN.md` records that half as deferred and warns that a reader seeing
`EntityPath` will assume otherwise.

The related defect is in `pony_analysis`: `DocumentFacts` computes
declarations, uses, bindings, foldable regions, diagnostics and a full byte
offset table in its constructor, so one keystroke recomputes all six. Split it
into per-fact queries. That is a change to a public constructor and it is
listed in the divergences above.

What this costs: `FINDINGS.md` calls it "a real piece of design rather than a
tweak", because bodies need identities that survive a sibling's edit. It is
the largest piece of work in this document that is not the type checker
itself.

## What is uncertain

Ordered by what being wrong would cost.

**1. Whether one actor is still the right shape once checking is the
workload.** `DESIGN.md` chose a persistent map published from one actor and
noted A's real cost is that it serialises — "while a cold check runs, the
actor answers nothing". Content-addressed identity removes the reason workers
had to coordinate, which makes multiple checking actors possible for the first
time. Nothing here designs that, and the memo store decision was taken when it
was not possible. It should be revisited before the slice is built, not after.

**2. Whether the engine's recursion survives a real dependency graph.**
`_bring_current` descends recursively and its docstring says nothing measured
says how deep a chain gets. A signature layer over the standard library is the
first thing that will find out, and a stack overflow is not a graceful
failure.

**3. Whether the ceiling is reachable.** 54.3% assumes the slice makes no
false rejection, and ponyq made 99. Every false rejection costs a point
directly, so a slice that is merely careless lands below the 46.1% floor. The
ceiling is what the cut permits, not what an implementation will get.

**4. The divergence-guard disagreement.** Bounding on structural depth rather
than ponyc's frame count will disagree on some inputs. `FINDINGS.md` says the
corpus will say how many; ponyq ran that corpus and the number is not recorded
in the sections I read.

**5. Whether `body_types` as one query per body is right in Pony.** ponyq's
argument is that two ponyc rules read an expression's *position* —
auto-consume in return position, and whether a call's result is used — so a
node-keyed query could not answer them. That reasoning is about the rules, not
the language, so it should carry. It has not been checked against Pony's
actor granularity, where the unit of concurrency is not the unit of
memoization.

**6. Whether skipping structural verification is acceptable for a worker that
keeps no deduplication map.** The bound is 9 x 10^-29 and the failure is
silent. I believe it is acceptable and I have not seen anyone else make that
trade in a compiler.

## A ponyc bug found while measuring

`DoNotOptimise[(U64, U64)]` — a tuple type argument — segfaults ponyc 0.69.1
(LLVM 22.1.6) in LLVM's X86 instruction selection. Deterministic, and it
reproduces at `--debug`. The scalar form compiles.

```pony
use "pony_bench"

actor Main is BenchmarkList
  new create(env: Env) => PonyBench(env, this)
  fun tag benchmarks(bench: PonyBench) => bench(_Tuple)

class iso _Tuple is MicroBenchmark
  fun name(): String => "tuple"
  fun ref apply() =>
    DoNotOptimise[(U64, U64)]((U64(1), U64(2)))
    DoNotOptimise.observe()
```

The crashing function is
`DoNotOptimise_val_apply_t2_U64_val_U64_val_2WWo`. `tools/type_hash` works
around it by observing one lane at a time.
