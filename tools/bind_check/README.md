# Does the Bound layer hold up on a real workspace?

`make bind` loads every file of ponyc's standard library into one `Binder`,
groups them into packages by directory, and checks three round trips:

- every entity a file declares resolves, from that file, back to that file
- every `use` names a package the workspace has
- every local, parameter, field and type parameter, asked about at its own
  name, comes back as itself rather than as another binding of that name

Neither can be satisfied by an index that is only self-consistent, which is
the point of a round trip.

## Result

Over ponyc's standard library, every entity resolves from its own file back
to itself, every `use` names a package the workspace has, and every local,
parameter, field and type parameter comes back as itself. Nothing is
unresolved, nothing resolves to the wrong file, and no `use` names a package
that is not there.

The totals are not recorded here, because they move whenever the standard
library does. What the check asserts is that none of the three round trips
fails, and that holds whatever the totals happen to be.

Over the whole ponyc tree rather than the standard library alone the entity
round trip also holds. The `use` check does not apply there, because those
files resolve their imports against the standard library's root rather than
against the tree they live in, and the tool is given one root.

## What it found

Both of these were correct against the unit tests and wrong against the
standard library:

- **`lib:` and `path:` are not imports.** ponyc has three `use` schemes and
  only `package:` -- the default when none is written -- names a Pony
  package. `lib:rt` links a native library. Reading it as an import invents
  a dependency on a package that cannot exist.
- **`use ".."` names the package one directory up.** The standard library's
  benchmark subpackages reach their parent that way, and without relative
  resolution they import nothing.
- **An FFI declaration opens a scope.** ponyc marks `use_ffi` with
  `SCOPE()`, and it is easy to miss because an FFI declaration does not
  look like one. `net/tcp_connection.pony` declares thirty
  `use @pony_asio_event_*` with a parameter named `event`, and without a
  scope each they were all visible over the whole file. That was 276
  bindings resolving to the wrong one.

The revision count is the third thing worth reading: one per file, one per
package, and the one the engine starts at. Nothing else advanced it, which
is the engine's backdating doing its job.
