# The semantic layer: design

Answers the six questions in `CHECKER_BRIEF.md`, plus a seventh the
evaluation showed was missing: package loading.

Produced by the full `pony-software-design` loop: three design personas
from different entry points, a synthesis, two rounds of five-persona
evaluation (the second on the revised candidate), and a focused re-check
of the revised mechanisms — an adversarial pass with compiled probes plus
a fidelity audit of the revision itself. The first candidate was rejected
outright; the later rounds produced adjustments, all applied. The two
policy decisions the loop surfaced — loader confinement and
guard-versus-shortcut divergence — are decided by Red and recorded where
they arise.

Nothing here is implemented. Claims marked *unverified* are exactly that;
a complete list is at the end. Measurements cited by name live in
`tools/memo_pays`, `tools/type_hash`, and `tools/corpus`.

## Divergences from what exists

1. **`Binder._engine` changes from `embed` to `let`, and `create` gains
   `engine': Engine = Engine`.** An embed field cannot hold an externally
   constructed object, so sharing one dependency graph between the binder
   and the checker needs this one-keyword change (cost: one indirection).
   The defaulted parameter keeps every existing caller and all 13 test
   sites compiling.
2. **`Binder.set_package_path` becomes per-using-package**: the map from a
   `use` string to a package gains the using package as part of its key.
   Today it is global, and a batch run that loads ~1,400 case packages
   through one process would accrete mappings across cases; the loader
   resolves per using package anyway, so it supplies the key naturally.
3. **`Engine` gains a re-entry trap, and dependency lists are deduplicated
   at frame pop.** `demand` of a query already being computed currently
   recurses to stack death; it becomes a located `_Unreachable` — an
   untested, crash-only backstop, since the design's discipline is that
   the engine never sees a cycle at all. The descent's depth over a real
   semantic dependency graph is *unverified*; a max-depth counter in the
   trust harness is the slice-2 gate on it. `_record_read` currently appends
   every read, so a dependency list is a demand log rather than an edge
   set; deduplicating on frame pop keeps revalidation walks O(distinct
   edges). No initial values, no fixpoint machinery, no result storage.
4. **`pony_syntax` gains a parser depth guard**, as a slice-0
   prerequisite. The parser today segfaults at roughly 15,000 nested
   parentheses (reproduced; about 20 KB of hostile input), and the batch
   driver is one process over every case, so one such file kills every
   verdict in the run. The guard turns the overflow into an ordinary
   diagnostic. Until it lands, the exit-code contract below is unmeetable
   on such inputs, and this document says so rather than promising it.
5. **The corpus instrument is rebuilt, in two steps, before any ceiling
   below is relied on.** `extract_corpus.py`'s pass detection reads only
   the one-argument `TEST_COMPILE` define, and three suites pass the
   target pass as a per-invocation macro argument, so the fix parses per
   invocation and records the pass per case in the manifest.
   `pass_reach.py`'s exclusion rule is then re-derived per case, and
   `corpus_report.py` asserts verdict-file completeness against the
   manifest so a mid-batch crash cannot yield a silent prefix rate.
6. **The first shipped binary is the driver, not the signature layer.**
7. **`DocumentFacts` is split into per-fact queries** — as its own
   reviewed change, off the checker's critical path. The batch argument:
   parse alone measured 297 ms against 447 ms for all six projections
   over the standard library (timed during the first evaluation round),
   so the checker pays 34% for projections it never reads. The
   constructor is public with consumers in `pony_bind`, both trust
   harnesses, `pony-lsp`, and 13 test sites — which is why it ships
   separately.

## Package loading

`Loader` lives beside the driver in `tools/checker` and is the only
component that reads disk or resolves a `use`. It runs to completion for a
package before that package is checked.

**The scheme table is ponyc's** (`use.c:32-144`), ported with its
per-scheme legality flags. The package scheme — a bare locator, or the
same written explicitly as `package:` — names a Pony package and is
resolved. `lib:` is a link-library directive and `path:` appends to
link-time library paths (`program.cc:171-196`); both are recorded and
skipped, as are the C-shim schemes. An unknown scheme is a diagnostic.
**Guards follow ponyc's legality table, not an evaluator**: the package
scheme has `allow_guard = false`, so `use "collections" if windows` is an
error, probe-verified — no package load is ever guard-gated. Guards are
legal only on the link-directive schemes, which this loader records and
skips regardless, so guard evaluation enters only with FFI declarations
in a later slice.

**Resolution order for a bare locator**, matching ponyc's `find_path` less
the upward `../pony_packages` walk: an absolute path as given; relative to
the using package's directory — and a locator written with an explicit
`./` or `../` that fails there fails outright, never falling through to
the roots (ponyc's rule); then each search root in order (`--path` flags,
then `PONYPATH`). `builtin` is resolved from the roots once, before the
walk. The upward walk is deferred; a scan of the extracted corpus found
zero relative `use`s and nothing needing it.

The loader walks the `use` graph a level at a time, reading each file's
imports back from the binder — the binder parses; the loader never does.
(Slice 0 as built takes an interim shortcut: the binder is not wired in
until name resolution arrives, so the loader owns the parse and scans
uses from the tree itself, recording each `use`'s guard and alias for
the legality checks. The binder takes the parse back in slice 1. The
loader's package cache also lives for the whole batch, cases included —
the per-case eviction the memo architecture requires arrives with the
engine, and until then a batch's footprint is linear in its case
count.)

**A package's identity is its canonical (realpath) directory path**,
carried as `PackageId`, whose constructor is private to the loader: a
`use` string can never become a package identity except through
resolution. (Slice 0 as built carries the identity as a bare canonical
path — every site canonicalises before use, and nothing yet crosses a
boundary where a raw locator could stand in. `PackageId` is owed when
the loader and binder meet in slice 1 and the identity starts moving
between components.) Two locators reaching one directory are one
package. Workers never resolve — every consumer reads the same
resolved mapping from the same inputs, so agreement on type identity
is by shared immutable input, not by protocol.

**Verdicts split as ponyq's do**: a root directory that cannot be loaded
is `load-failed`, and so is a run that cannot resolve `builtin` — that is
a precondition of checking anything, not a `use` inside the program. An
unresolvable `use` inside a loaded program is an ordinary ponyc-shaped
diagnostic and the verdict is `fail`. In single mode a load failure
prints the `LoadError` and exits 255. The distinction matters
operationally — a misconfigured search path reads as load failures, not
as a wall of spurious rule rejections.

Errors are data: `LoadError` is `(UnloadableRoot | UnreadableFile |
EmptyPackage)`. An earlier draft carried an `AmbiguousUse` variant for one
`use` string resolving to two directories; the per-using-package map
(divergence 2) dissolves that class — resolution is first-match and
deterministic per (using package, string), so two packages resolving one
string differently is supported, not ambiguous — and an unreachable error
variant earns no place in the vocabulary.

**Confinement: ponyc parity, documented — decided by Red.** Dependency
`use` strings are written by whoever wrote the dependency; the loader
honours absolute paths and diagnostics echo source lines from whatever
was loaded, exactly as ponyc does (verified against `package.c`). Running
the checker over a workspace therefore trusts that workspace's
dependencies to the same degree compiling it with ponyc would. The
confinement alternatives (a workspace root, a batch-only restriction)
were considered and declined; revisit only if the checker acquires a
deployment where it runs over source nobody chose to trust.

## The type IR, and identity

### The IR

ponyq's `hir.rs` ported as a Pony union, so matches are exhaustive:

```pony
type Ty is
  ( Nominal | AliasRef | TypeParamRef | UnionTy | IsectTy | TupleTy
  | Arrow | LambdaTy | CapType | IntLit | FloatLit | ThisType
  | DontCare | ErrorTy )
```

Kept decisions, each with its recorded reason from `FINDINGS.md`: aliases
unexpanded (expansion does not terminate; ponyc permits self-reference
through type arguments); `TypeParamRef` stores the capability *as
written*, `(Cap | None)` — computing the effective capability during
lowering is the cycle ponyq removed by not computing it there; lambda
types stay structural, subtyped as a one-`apply` interface; `ErrorTy` is a
subtype and supertype of nothing, so one bad type does not cascade;
`IntLit`/`FloatLit` distinct from every concrete numeric type. `eph` is
part of the value on every capability-bearing variant: `String iso` and
`String iso^` are two types.

`Nominal.def` and `AliasRef.def` are `EntityPath`; `TypeParamRef.def` is a
`TypeParamPath` (owner path, optional method name, parameter name). No
node indices anywhere in the IR. Every `Ty` also carries `depth: U32`,
folded at construction: lowering refuses a type past a configured depth
with an ordinary diagnostic, and the same field bounds the recursive
walks (equality, hashing, the canonical compare) so no walk recurses
past what lowering admitted.

**Every variant's constructor is package-private; the public surface is
factory functions that consult the deduplication map.** A `Ty` that
exists is therefore canonical by construction, which is what the
reflexive shortcut and the memo fast path below rely on — an invariant
the compiler enforces at the package boundary rather than a hit rate to
hope for.

### Identity: structural equality decides; the hash accelerates

- Every `Ty` carries a cached 64-bit structural hash, folded from its
  children's cached hashes at construction — O(1) amortised, measured in
  `tools/type_hash`.
- `Ty.eq` is: `is` (pointer identity — the common case, since
  construction deduplicates), else hash mismatch answers `false`, else a
  full structural walk answers. The `EntityPath` precedent: hash as fast
  path, equality as the decision.
- **Deduplication is inherent**: each checker owns a `HashMap[Ty, Ty]`
  with hash = cached hash and eq = structural, consulted by every
  factory. The map's own bucket handling is the collision handling.

A hash collision costs a wasted structural walk (measured at 809 ns per
walk, paid once per distinct type), never a wrong verdict. There is no
probability to state, no hash function to approve, and no collision
failure mode; the existing FNV-style fold is retained because its quality
affects only speed. One composed measurement remains to take before
building: the actual construction path — a mutable `HashMap[Ty, Ty]` with
a custom hash function, probed with a fresh non-canonical key over
canonical children — since the existing benchmarks price its pieces
separately (*unverified* as a composition; the pieces suggest roughly
0.1 s per standard-library check).

**Canonical form, enforced at the only construction site.** The
`UnionTy`/`IsectTy` factories flatten nested same-kind children,
deduplicate by structural equality, and sort by a total structural order
on `Ty` (variant tag, then fields, then children; the cached hash orders
as a fast path with the structural order as tiebreak, so a collision
cannot destabilise the sort, and the order consults neither pointer
identity nor map iteration order — it is deterministic across checkers).
`(A | B)` and `(B | A)` lower to one value.

**Stated plainly:** structural equality is not Pony type equality —
aliases stay unexpanded, so an alias and its expansion are different `Ty`
values. Semantic questions go through subtyping, which unfolds.

## Where the sugar goes

Sugar that only affects checking is applied on the way past and never
materialised. Sugar that changes what a signature contains — default
`create`, a primitive's `eq`/`ne`, default return types — is synthesised
inside `method_table`, after inheritance, so inherited members win. The
ordering is load-bearing and invisible in a query decomposition, so it is
pinned by a direct test on `primitive Less is Equatable[Compare]`
(verified against `traits.c:841-947`), not by a corpus run at a distance.

## Cycles

### The phase rule: lowering and synthesis never invoke subtyping

Constraint checks and provides checks are diagnostics queries over
*completed* method tables; lowering and `method_table` synthesis never
call the subtype evaluator. Without this rule, `class Foo is
Comparable[Foo]` — the standard library's most common generic pattern —
would demand `method_table(Foo)` while Foo's own query is mid-run and hit
the engine trap. ponyc's traits pass makes the same possible: it never
calls `is_subtype` (verified — its signature comparison is structural).
This diverges from ponyc's placement of constraint checks in its names
pass, and the divergence is forced by the memoized shape.

### The engine never sees a cycle

Signature-level cycles are prevented by construction — `entity_kind` and
default capabilities come from `BoundItem`, already computed by
`pony_bind`, so lowering never asks a signature for what a bind fact
answers — or detected before `demand`: `method_table`'s accessor checks a
`_computing` set and returns a distinct `MethodTable.cyclic(entity)` on a
provides cycle, so no cycle edge ever enters the engine's dependency
lists. The re-entry trap is the backstop if the discipline slips.

**`MethodTable.cyclic` propagates and fails closed.** A table with a
cyclic provider is itself cyclic; every consumer treats a cyclic table
the way subtyping treats `ErrorTy` — nothing is concluded from it. The
memo exclusion has a mechanism, not just a rule: touching a cyclic table
ORs poison into the current frame, so a verdict computed against one
classifies `_Poisoned` and never reaches the durable memo. The
user-facing diagnostic comes from `provides_acyclic`, a
name-level walk with a visited set that runs before synthesis and reports
ponyc's own error; the dynamic `_computing` guard only keeps the
computation finite, and a disagreement between the two is a defect the
counters surface (below) makes observable.

### The subtype evaluator owns coinduction

One plain recursive function — not engine queries — with an explicit
per-top-level-call context: an assumption stack pushed at the pair shapes
ponyc guards; a repeated pair returns `true` (the coinductive base case),
recording the matched frame index.

**Each frame carries two accumulators, ponyc's discipline ported with its
merge rules** (`subtype.c:1859-2075`): the minimum matched assumption
index (merged by minimum into the parent on every exit) and a poison flag
(merged by OR into every ancestor). The two are orthogonal — a result can
lean on an open assumption *and* sit above a poisoned bail — and the
classification site reads both, poison dominating:

```pony
primitive _Discharged
primitive _UnderAssumption
primitive _Poisoned
type _Dependence is (_Discharged | _UnderAssumption | _Poisoned)
```

**Only `_Discharged` results are ever stored durably — and nothing else
is stored at all.** A result whose derivation leaned on an enclosing
in-progress assumption is returned to its caller and discarded: no
parking, no promotion, no per-call conditional table. This is the
smallest sound discipline, and it is stricter than ponyc's: ponyc caches
results conditional on the top-level assumption behind read gates and
refuses to cache only the intermediate-dependent case ("the entry would
depend on an intermediate assumption with no clean invalidation hook");
discard-only takes the refusal for both classes. An earlier draft's
promotion-on-confirmed-head mechanism was shown by evaluation to memoize
a wrong, order-dependent verdict on a constructed multi-entity program
(the program is retained as a required unit test alongside the
four-interface walk-order case; the four-interface case alone cannot
catch this class). The cost is
re-derivation of in-cycle pairs within a top-level call, bounded by the
number of derivation *paths*, not by cycle size — on a ring of interfaces
whose members reference the next member twice, that is exponential, and a
compiled probe measured exact 2^N growth on a 46-line legal file (ponyc
itself is exponential on the same probe, so this is no regression, but
one such case would stall the single-process batch). So the walk carries
a per-top-level-call work budget that surfaces "this check is too
complex" as an ordinary bounded diagnostic — the same pattern as the
parser depth guard — with the budget's value set from a stdlib
measurement. A counter still watches ordinary re-derivation volume, and
ponyc's conditional-read gates remain the recorded, measured follow-up
for making such programs actually check.

The durable memo lives in **its own small package**, whose public
`insert` takes the `_Dependence` union and classifies internally; the
settled-verdict type never leaves it. The single-construction-site
property is thereby structural — enforced by a package boundary the
compiler checks — rather than a review convention. The memo persists
across top-level calls (`Array[A] <: Seq[A]` is discovered once, the
sharing ponyc cannot have) subject to the batch partition rule below.
The three defensive cycle families ponyq recorded — none reached by the
standard library — get the same base-case treatment inside the walk at
the places they occur, when a slice reaches them.

**The divergence guard is ponyc's, verbatim.** At a nominal/nominal pair
whose definitions already appear `SAME_DEF_LIMIT = 4` times on the stack
with drifting arguments: bail `false` before pushing a frame, OR poison
into every ancestor, cache nothing. **The bail is silent on the deciding
path** — a bail inside one branch of a union that succeeds another way
must not surface, or an accepted program takes a false-rejection point.
The explain re-run reaches the same bail deterministically (nothing was
memoized) and surfaces ponyc's wording there. **The guard runs before
the memo lookup**: a durable hit must not pre-empt a bail, or the verdict
depends on what ran earlier in the process — ponyc's per-call cache clear
is what makes its guard deterministic, and this design deletes the clear,
so the ordering carries the burden instead. The warm-versus-cold pair is
a required unit test beside the promotion counterexample. Same rule, same
constant, same `pony_check`-refuted K=2 history. (`Ty.depth` is the
*input* bound at lowering; it is not the divergence guard.)

**Guard-versus-shortcut divergence: keep the correct shortcut — decided
by Red.** The reflexive shortcut and the same-def guard compose into a
divergence ponyc does not have: on a generic interface nested past the
guard's limit, ponyc's deciding frame is a *reflexive* pair and it bails
`false` (probe-verified against 0.69.1, ponyc's own #1216 wording), while
this design's shortcut answers that same canonical pair `true` before any
frame is pushed. The shortcut's answer is the semantically correct one;
ponyc's is the conservative bail it documents as issue #1216, and ponyc
is deliberately not changed for this. So the checker accepts some
programs ponyc's guard rejects, and the divergence is documented here
rather than reproduced. The measured corpus cost is zero: exactly two
corpus rejections are guard-decided, both genuinely growing chains
(`Iter[(B, A)]`, `I[I[A]]`) that the verbatim guard port rejects
identically, and no corpus case sits in the divergence class itself.

**The reflexive shortcut** answers `sub is sup` as `true` before the
memo, ported from the working PoC (`subtype.rs:1251-1330`) in its
original allowlist form: the shortcut applies only to variants whose
capabilities are syntactically decisive — a `Nominal`, `UnionTy`,
`IsectTy`, `TupleTy` or `LambdaTy` with no generic capability (`#read`,
`#send`, `#share`, `#alias`, `#any`) anywhere inside it, recursively —
and everything else is refused: `TypeParamRef`, `AliasRef`, `Arrow`,
`ErrorTy` (fail-closed), and the leaf variants, which is the PoC's
catch-all refusal. The rule is deliberately mode-blind, which is
conservative in every mode. Its precedence over the divergence guard is
the decided divergence above.

### Modes

Distinct public entry points (`subtype`, `eqtype`, `constraint_ok`, ...)
over one internal function taking a closed `SubMode` union that is part
of the memo key — ponyc's own boundary (five public functions over one
`check_cap_t` that sits in its cache key).

## Diagnostics

Value-returning queries carry their diagnostics as a field of the result.

For subtyping: **one function with an optional reason sink**, `reasons:
(ErrorFrame | None) = None` — ponyc's literal shape. With `None`, the
memo is consulted and fed; with a frame, lookup and insertion are both
skipped (a hit would short-circuit the recursion that writes the frames).
Explaining is re-running the same function with a sink after a memoized
`false`, once per reported error. There is no agreement invariant because
there are not two bodies to drift. If a rejection's re-run attaches no
reason, the checker still prints the pair, the mode, and a generic line —
failure is never silence — and the corpus explain mode counts it as a
defect.

**The checker exposes a read-only counters surface** — settled inserts,
memo hits, discards of under-assumption results, poisons, reflexive
short-circuits, and cyclic tables produced — so the soundness-critical
machinery is asserted on directly by unit tests instead of only through
end-to-end verdicts, the memo-content claims ("poisoned never cached",
"reflexive makes no entry") each become a one-line assertion, and a
`provides_acyclic`/`_computing` disagreement is visible as a cyclic count
with no matching diagnostic.

**A public accessor resolves a name to its canonical type** —
`entity_type(EntityPath)` and `field_type(MemberPath)` — which is how a
test acquires `Ty` operands from a string-literal workspace (the existing
fake-builtin idiom, verified present in the current suite) and how the
explain path names what it is talking about.

### The oracles

Named, because a verdict corpus alone shipped ponyq 99 wrong rejections
it never noticed:

1. **The corpus**, floor-relative, per case — the headline gate.
   Diagnostics render with program-level load failures first, then in
   package load order, file order, and byte order within a file. In
   explain mode, ponyc's expected message — which `extract_corpus.py` already
   stores in the manifest — is substring-matched against *all* of the
   case's emitted messages rather than only the first, since ponyc's own
   first message depends on its pass ordering, which this design does not
   reproduce. A case whose expected message matches none emitted is the
   rejects-for-the-wrong-reason defect a binary verdict cannot see.
2. **`tools/sig_agreement`**: `method_table` printed per entity and
   diffed against `ponyc --pass=traits --astpackage` over the standard
   library. The probe has been run: the dump is on stderr, is total over
   the stdlib, and contains the synthesised members — but it expands
   aliases, includes bodies, synthesises members beyond this design's
   list, and uses positional package ids, so **the normalization is part
   of the oracle's definition**: aliases expanded at print time on our
   side, ponyc's side stripped to signature fields, package ids mapped
   through the loader, and any unexpected ponyc-side synthesis reported
   as a finding rather than waved through.
3. **`--paranoid`**: every memoized subtype answer recomputed via the
   reason-sink path — which skips the memo by construction — **twice**,
   so a mismatch classifies: cold differing from cold is walk
   nondeterminism; cold stable but differing from the memo is unsound
   classification. A recompute that consulted the memo would reproduce
   its errors and be worthless. CI-only; also run across case boundaries
   in batch to gate the partition rule below.
4. **The existing gates**: the standard library checks clean; the whole
   ponyc tree parses.

## The first slice

Three slices, each a working binary over the full harness, each with its
ceiling measured by a proxy that matches its own cut. The first
implementation act was rebuilding the instrument (divergence 5) and
re-measuring, and it is done: the numbers below are measured, per case,
over the 1,371 valid cases (51 invalid excluded and listed by the
instrument; the measured floor is 45.4%). Two scales are in play: the
floor counts every valid accept, while the scored rate flips the
pass-limited accepts — the cases full ponyc rejects — so on the scored
scale an accept-everything checker sits three points lower. A quoted
percentage is on the floor scale unless it comes from
`corpus_report.py`, which scores. The reopen trigger — a collapse
toward the signature layer's 3.5 points — did not fire; the ceilings
roughly doubled instead, because the old instrument excluded whole suites
whose target pass was declared per call site, the 126-case `syntax` suite
among them.

**Slice 0 — driver, loader, parse and syntax legality.** The binary; the
`--batch` contract verbatim ponyq's, so the harness scripts run
unmodified (`<dir>\t(ok|fail|load-failed)`, exit 0 for the batch; single
mode exits 0 clean / 255 with ponyc-shaped errors off `LineIndex(Utf8)`;
a usage error or internal failure exits 1, distinct from both
verdicts — a crash never manufactures one); the loader; the parser
depth guard (divergence 4); and ponyc's `syntax`-pass legality rules — body-free shape checks
over the existing lossless tree. Measured: 130 rejections error at
`parse` or `syntax`, **+9.5 points**. Whether the deliberately tolerant
parser converts its facts into all 130 verdicts is the open caveat this
slice closes.

**Slice 1 — name errors.** `pony_bind` wired to the loader: unresolved
names and unresolved `use`s as diagnostics (the `fail` side of the
verdict split — nothing here scores as `load-failed`, so no case is
double-booked). Measured: 41 rejections error in
`sugar`/`scope`/`import`/`name`, **+3.0 points** (*unverified* how many
are body-free).

**Slice 2 — signatures.** The IR, lowering with canonicalisation, the
capability algebra (pure table ports), `method_table` with synthesis,
**the type-alias recursion legality check** (ponyc's dedicated pass;
ponyq stack-overflowed until it ported the rule; 3 corpus rejections and
a crash risk without it), reification as a plain function, the subtype
evaluator, provides and constraint checking under the phase rule.
Measured: 50 rejections error in `typealias_recursion`/`flatten`/
`traits`, **+3.6 points**. The ~26 signature-level checks ponyc reports
from its `expr` pass are unverified upside, excluded from every ceiling
until a per-case audit separates them from body machinery; 528 measured
rejections need `refer` or later.

Cumulative measured ceiling: 843 of 1,371 — **61.5%, +16.1 points over
the 45.4% floor** — assuming zero false rejections, and every false
rejection costs a point, which is what put ponyq's 99 nearly on the
floor. The per-slice gates (stdlib clean, tree parses, `sig_agreement`
empty after normalization) are the false-rejection defence.

Bodies cannot precede signatures — `body_types` reads signatures and no
other body (`FINDINGS.md`) — but nothing says signatures must precede the
driver, and the brief's own measure (rejections over the floor at every
stage) points driver-first.

## Granularity

**Name-path keying: now, as the identity scheme.** Every query is keyed
by `EntityPath`/`MemberPath`; no `Ty`, signature, or memo mentions a node
index. This is the half of the granularity fix that must precede the
layer, costs nothing new, and means ponyq's three measured
positional-identity costs never arise — which `tools/memo_pays` showed is
what reverses `FINDINGS.md`'s batch-versus-server fork arithmetic.

**Item-relative spans: deferred to the LSP brief.** Every number for them
is an edit-workload number and this binary performs no edits.

**`DocumentFacts` split: its own change** (divergence 7).

## The memo architecture, and the batch run

- **Entity-level queries** (`entity_sig`, `method_table`,
  `entity_diagnostics`, `package_diagnostics`) run on the **shared
  engine** — checker and binder on one graph (divergence 1), caller-held
  typed tables, `pony_bind`'s exact pattern. The checker's `run` forwards
  binder-owned query ids to the binder (one `QueryId` space, two runners;
  the forwarding is part of the design, stated because nothing in a batch
  run would otherwise exercise it). Resolution mappings
  (`set_package_path`, `set_builtin`) are load-time inputs that do not
  change within a run; making them engine-revisioned inputs, and giving
  the subtype memo per-key dependency registration instead of the
  partition-and-drop rule, are the two recorded LSP-era extensions.
- **The batch run is one process over one shared database** — ponyq's own
  shape, so the standard library is parsed and checked once across ~1,400
  cases. **This means the revision advances on every case load**, so the
  memo rules are scoped by what a revision change can actually invalidate:
  settled subtype entries and entity tables whose keys mention only
  packages under the search roots (decidable at key construction, since
  an `EntityPath` carries its package) survive across cases; entries
  mentioning a case package are dropped when that case completes.
  Root-stability for a `Ty`-keyed entry is not decidable from a path
  alone — a case package can hide in a nominal argument or a lambda's
  parameters — so every `Ty` folds a `root_stable` flag at construction,
  exactly as it folds `depth` and its hash. The dedup map sits outside
  the partition rule and only accretes memory; it shares the
  admitted-input ceiling below.
  The invariant this rests on: case directories are disjoint from each
  other and from the search roots, and within one run a canonical
  directory path outside the case set maps to immutable content. The cross-case
  `--paranoid` sweep is the empirical gate on it, and a corpus wall-clock
  number joins the slice-0 gate.
- **The engine choice is forced, not preferred**: the alternative
  (checker-private flat maps stamped with the binder revision, flushed
  whole on mismatch) would flush builtin's tables ~1,400 times per corpus
  run. The shared engine with the partition rule is what makes the batch
  instrument affordable.
- **The subtype evaluator's memo** is a flat mutable map (measured
  cheaper than the persistent alternative on both axes for this
  workload), keyed on canonical `Ty` instances plus `SubMode`, and
  partitioned by the same root-stable rule.
- **Plain functions**: `lower_type`, the capability algebra, `reify` —
  each measured or reasoned at R = 1, where a memo cannot pay.
- **One checking actor.** Multi-actor checking is a recorded extension;
  structural identity keeps it possible (agreement by shared resolved
  input), and ponyq's measurements (2.25x recompute sharing nothing, 19%
  for removing sharing entirely) say parallelism is not where the next
  win is.

## Resource bounds

The driver owns "this input is too large", in three places, each
surfacing an ordinary diagnostic rather than a crash: a per-file byte cap
at load; the parser depth guard (divergence 4); and the `Ty` depth bound
at lowering, which also bounds every recursive walk over types. Every
growable table then inherits a ceiling from admitted input: the dedup map
and subtype memo are bounded by the distinct types constructible from
capped sources, and `Engine._entries` — which grows one entry per
registered query and never shrinks — by the file, package and entity
counts the byte cap and the walk admit. No eviction policy exists or is
needed for a batch run; the per-case drop rule bounds cross-case
accretion in batch.

## Key decisions, and what settled them

**Identity: structural-decides over digest-decides.** Two of three design
personas independently chose the `EntityPath` precedent; the repaired
digest alternative needed a hash-function approval, an avalanche gate, an
abort path, and a forced-collision test, and still carried a multi-actor
residual. Structural-decides needs none of those. Evaluation then
verified the surviving claim at every use site: no path from a hash
collision to a wrong verdict.

**Cycles: discard-only over park-and-promote.** The promotion mechanism
was adopted in an earlier draft on the claim it was ponyc's argument
ported; evaluation showed ponyc has no promotion to port and built a
constructed multi-entity program where promotion durably memoizes a wrong,
order-dependent accept. Discard-only is ponyc-faithful, dissolves the
parked-entry read-path question entirely, and its re-derivation cost is
watched by a counter with ponyc's conditional-read gates as the measured
fallback.

**The engine: shared, because batch forces it.** An earlier draft
presented this as a near-free preference for LSP readiness; the batch
analysis (one process, ~1,400 case loads) showed the alternative flushes
the standard library's tables per case. The LSP benefit is real but
secondary.

**The divergence guard: ponyc's verbatim.** A structural-depth bound on
the key was considered (memoizable), rejected because poison-and-never-
cache satisfies the memo constraint without introducing a documented
disagreement class with ponyc.

**The explainer: one body.** A two-path design with a tested agreement
invariant was considered and rejected: the invariant tested non-emptiness,
not agreement, and one body cannot drift from itself.

## Unverified claims (complete list)

1. Whether the tolerant parser converts its facts into slice 0's 130
   measured verdicts — the slice ceilings themselves are now measured
   per case (`tools/corpus/reach.tsv`), and the reopen trigger did not
   fire.
2. That discard-only's in-cycle re-derivation is affordable — the counter
   at the stdlib gate answers it; ponyc's conditional-read gates are the
   fallback.
3. The promotion counterexample program and the four-interface
   walk-order case both become unit tests before the settled memo is
   trusted; the classification claims are "ponyc's argument, ported with
   its conditions" until then.
4. The composed construction-path cost (dedup probe with custom hash on
   the real map shape) — one benchmark variant, mostly existing code.
5. How many of the 42 name-level rejections are body-free.
6. The work budget's value, set from measurement at the slice-2 gate.
   (The guard-divergence corpus frequency is measured: zero cases in the
   class; two guard-decided rejections, both handled identically by the
   ported guard.)
7. The cross-case memo partition's invariant (root-package content
   immutable within a run) — gated empirically by the cross-case
   `--paranoid` sweep.
8. The engine's recursion depth over a real semantic dependency graph — a
   max-depth counter in the trust harness is the slice-2 gate.
9. The ~26 `expr`-pass signature checks' separability from body
   machinery.

## Kept from the first candidate

The IR shape and its four decisions; the sugar split and the `Less is
Equatable[Compare]` test; the floor framing (measured at 45.4% on the
per-case instrument's valid universe); diagnostics as result
fields; `ErrorTy` failing closed; the `--batch` CLI contract; driver exit
codes; the reason-sink explainer direction. Dropped across the two
evaluation rounds: digest-as-identity and its collision analysis; the
parallel-ceiling justification; the two-path explainer; park-and-promote;
the structural-depth divergence guard; the unpartitioned batch memo; and
the original 54.3%/+8.2 ceiling, which was measured with a proxy that did
not match the slice.
