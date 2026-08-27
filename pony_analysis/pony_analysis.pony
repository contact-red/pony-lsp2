"""
# Pony Analysis

What a language server needs to know about a Pony source, projected from a
syntax tree.

This layer holds facts about the code -- declarations, foldable regions,
diagnostics -- in lines and characters rather than byte offsets, because
that is what a client asks in. It holds no protocol vocabulary: no JSON, no
markdown, no LSP types. Turning a fact into a response is the server's job,
and keeping that out of here is what lets anything else use the same facts.

At this depth the facts are a pure function of the tree, so nothing here
needs memoizing. Depths that need names resolved or types known do, and
that is where a query engine goes.
"""
