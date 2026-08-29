"""
# Pony Query

An incremental computation engine: what salsa does for `ponyq`, without the
macros salsa needs and Pony does not have.

The engine holds no results. It holds, for each query, when its result last
*changed*, when it was last *verified*, and what it *read* while computing.
That is enough to answer the only question incrementality asks -- is this
memoized result still good? -- and it is all that can be held generically,
because dependencies cross query kinds and a graph over heterogeneous typed
values would have to be a graph over `Any`.

So results live in the caller's own typed tables, keyed by `QueryId`, and the
caller interns its own keys. Interning is where "two structurally equal types
get the same key" is decided, and only the caller knows what its types are.

## The shape of a query

```pony
class Types
  let _engine: Engine = Engine
  let _ids: Map[Expr, QueryId] = _ids.create()
  var _results: Map[QueryId, TypeFacts] = _results.create()

  fun ref type_of(e: Expr): TypeFacts =>
    let q = _intern(e)
    _engine.demand(q, this)   // ensure it is current, and record the read
    try _results(q)? else TypeFacts.none() end
```

`demand` does two things at once, and it has to: asking for a result while
computing another one *is* the dependency edge, and an engine that made the
caller record it separately would be an engine that silently loses edges when
the caller forgets.

## Backdating

`QueryRunner.run` returns whether the recomputed result *differs* from the one
it replaced. Returning `false` is what makes an edit cheap: the query re-ran,
but its dependents keep their memo and do not.

`FINDINGS.md` measured this as the cheapest large win -- it is why a `//`
comment edit cost 1 query out of 20937 rather than all of them.

## What is not here

Cycle handling. `FINDINGS.md` reports exactly one inherent cycle, `is_subtype`
coinduction, and nothing below subtyping reaches it. Adding the machinery
before the query that needs it would be building for a predicted change.
"""
