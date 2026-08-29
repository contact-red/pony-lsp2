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

    files 255, packages 37, revision 293
    entities 1547, unresolved 0, wrong file 0
    uses 184, naming no known package 0
    bindings 12470, not resolving to themselves 0

Over the whole ponyc tree rather than the standard library alone -- 967
files, 365 packages -- the entity round trip also holds for all 3883
entities. The `use` check does not apply there, because those files resolve
their imports against the standard library's root rather than against the
tree they live in, and the tool is given one root.

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
  scope each they were all visible over the whole file. That was 276 of the
  12470 bindings resolving to the wrong one.

The revision count is the third number worth reading: 293 for 255 files is
one per file, one per package, and the one the engine starts at. Nothing
else advanced it.
