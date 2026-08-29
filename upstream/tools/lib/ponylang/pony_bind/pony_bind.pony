"""
# Pony Bind

Which declaration a name refers to, across the files of a workspace, from
syntax alone.

This is the depth `DESIGN.md` calls `Bound`: enough to answer where a type is
declared, what a package exports, and what a workspace contains, without
inferring a single type. Everything that needs a receiver's type -- a method
call, a field access -- is above this layer and is not here.

## Positions are not in the memoized values

`FINDINGS.md` names file-level invalidation as the limiting flaw: an arena
index shifts when anything earlier in the file changes, so an edit to one body
invalidates everything the file declares. The fix it names is addressing items
by name path.

So `BoundItem` carries a name path, a kind and a file, and no span. Editing a
method body changes no name, no kind and no file, so the declaration list
compares equal, the engine backdates it, and the package index does not
rebuild. Spans are looked up afterwards from the one document that has them.

That is the whole reason the values are shaped this way, and putting a span in
`BoundItem` would quietly undo it -- the index would still be *correct*, and
would rebuild on every keystroke.

## What is a query and what is not

Queries are the expensive aggregations: parsing a file, projecting what it
declares, and unioning those across a package. Resolving one name is a map
lookup, and `FINDINGS.md` says not to memoize what is cheaper to recompute, so
`Binder.resolve` is a plain function.

It still calls `demand` on what it reads. Called from inside another query
that edge is recorded; called from outside there is no frame and nothing is
recorded. Resolution composes into a memoized caller without knowing whether
it has one.
"""
