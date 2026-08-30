# Does memoizing a subtype decision pay?

`FINDINGS.md`'s "The fork" says it does not, for the product this project is
now building:

> For a **batch compiler** the memoization is a cost with no return: at least
> 17% of the check phase goes to lookups, and it does not improve
> parallelism. A parallel pass pipeline over the same immutable AST,
> memoizing nothing, would plausibly be faster than this -- untested, and
> cheap to test.

`CHECKER_BRIEF.md` moved this project onto that side of the fork, so the
claim has to be answered before a semantic layer is built on memoized
queries.

## What the claim reduces to

A query asked `R` times per distinct key costs `R*L + C` memoized and `R*C`
not, where `L` is a lookup and `C` a recompute. So memoizing pays exactly
when

    L < C * (R - 1) / R

`FINDINGS.md` measures `R`: 24 for `is_subtype` (281,352 calls, 11,552 runs)
and 1 for `lower_type` (22,154 on 22,154), where no memo can ever pay. What
it does not measure is `L` and `C` in Pony. `make memo-pays` measures both.

## Result

Baseline-subtracted medians over three runs:

| | ns |
|---|---|
| lookup, flat `val` map | 261 |
| lookup, persistent map | 293 |
| recompute, depth 2, equal | 577 |
| recompute, depth 4, equal | 3,850 |
| recompute, depth 4, differing at a leaf | 1,133 |
| answer by digest equality, no memo at all | 236 |

Which puts the crossover at **R > 1.8** for a depth-2 type and **R > 1.1** for
a depth-4 one. A memo pays as soon as a key is asked about twice, and
`is_subtype` is asked 24 times.

## Why this differs from ponyq

ponyq's lookup cost about 1,500 ns — `FINDINGS.md` derives it from a
reflexive shortcut that removed 39,580 calls and 0.06s. Here a lookup is 261
ns, 5.7x cheaper, and the reason is in `FINDINGS.md` too: salsa "interns the
argument tuple of a multi-argument query on *every* call, hit or miss", and
`ast_of` runs 1,082,246 times to turn a `NodeRef` back into a pointer.
`FINDINGS.md` attributes all of it to positional identity and says an item
tree addressed by name "removes all three costs at once".

This design has neither cost. `pony_bind` already addresses declarations by
name path, and `SEMANTIC_DESIGN.md` keys the subtype memo on canonical type
values deduplicated at construction, so there is no interning table and
nothing is interned per call.

**So "memoization is a cost with no return" is a property of positional
identity plus salsa's interning, not of memoization.** Remove those and the
arithmetic reverses.

## What this does not settle

The unit decision, not the architecture. Racing a whole memoizing-nothing
pass pipeline against a query pipeline needs both to exist, and neither does.
What is settled is the premise the fork's claim rests on: a lookup here is
cheaper than the work it saves, by 2x at the shallowest realistic type and
15x at a normal one.

Two things carry over from `FINDINGS.md` unchanged. `lower_type` at `R = 1`
is a memo that cannot pay, so its rule stands: memoize at entity boundaries
rather than node boundaries. And the digest-equality shortcut answers in 236
ns without consulting anything, so the cheapest call is still the one not
made.

`_Subtype` here does less per node than a real subtype check — `subtype.rs`
is 1,950 lines — so `C` is a floor. That understates the case for
memoizing, which is the safe direction for the conclusion.
