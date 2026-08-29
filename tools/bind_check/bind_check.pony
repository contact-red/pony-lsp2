"""
Whether the `Bound` layer holds up on a real workspace.

Unit tests cover cases someone thought of. This loads every Pony file named
on the command line into one `Binder`, groups them into packages by
directory, and checks two things that must hold for all of them:

  - every entity a file declares resolves, from that file, back to itself
  - every `use` names a package the workspace has

Both are round trips, so neither can be satisfied by an index that is merely
self-consistent.
"""
