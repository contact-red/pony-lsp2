# The batch checker

A binary that loads a package and everything it `use`s, and rejects
on parse diagnostics, over-deep nesting, `use`-level legality and
resolution errors, ponyc's syntax-pass legality rules, its scope-pass
`can't reuse name` rules, its import-pass clash rules, invalid
provides types, and unresolved names, in ponyc's own wordings. Name
lookups fail open: a name the resolver cannot prove unresolvable is
accepted, so a resolver gap costs a missed rejection rather than a
false one. The largest such gap is lambda bodies — a lambda's members
are not in any table, so no name failure under one is reported. The
alternate-name suggestion's case search is partial the same way: it
sweeps this file's bindings and the entity tables, but not the
members of enclosing entities, so a member differing only by case
goes unsuggested.

    checker <package-dir> [--path=ROOT ...] [--files]
    checker --batch=<cases-file> [--path=ROOT ...] [--files] [--errors]

`--batch` and `--path` also take a separate argument:
`--batch <cases-file>`, `--path ROOT`.

Single mode exits 0 when there is nothing to report and 255 with
ponyc-shaped errors otherwise; a usage error or internal failure exits
1. Batch mode emits one tab-separated `<dir>` and `(ok|fail|load-failed)`
line per case and exits 0. `PONYPATH` entries are search roots after
every `--path`. `--files` reports each file as it is opened, to
stderr in ponyc's wording; a file served from the batch cache is not
re-opened, so it is not re-reported. `--errors` renders each `fail`
or `load-failed` batch case's diagnostics to stderr under a
`<case>:` heading naming the case as its verdict line does; single
mode always renders diagnostics, and rejects `--errors` as a usage
error. The verdict lines on stdout are unchanged.
`--files` lines are written as loading runs, not placed by the
headings, so one can land inside any case's block; a package opened
for one case is not re-opened for the next, so an `Opening` line
appears once, at the first case whose load opened it. The two
streams are written independently, so read them separately; merged,
their lines interleave without order.

Diagnostics report in stages. Parse diagnostics report alone,
then legality and load together. Past that, each family carries
the ponyc pass its rule runs in — scope (reuse), import (clash),
name (the private-type check on a nominal, and nominal types),
flatten (entity provides), refer (references), expr (the
private-type check on a qualified expression, island reuse,
object-literal provides) — and a family that fails its pass
suppresses every later pass. The families of one pass report
together. Where ponyc's traversal stops at the first finding of a
pass, the checker reports the whole family. The two private-type
checks fail no pass: ponyc reports them and keeps going, so when
they are the only families reporting, nothing is suppressed.
Fixing everything one run reports can therefore surface a later
pass's findings on the next run.

The layers: `loader.pony` is the one component that reads disk or
resolves a `use`, and drives every whole-program rule family over
its caches; `uses.pony` projects each file's `use` declarations
with their schemes classified by ponyc's table; `legality.pony` is
the ported syntax-pass rules; `reuse.pony` is the reuse rules — the
scope-pass family, and the expr-pass family a lambda's or object
literal's desugar raises — over the same bindings projection the
resolver reads; `provides.pony` is the invalid-provides rule; the
import-clash rule lives with the loader, which alone holds every
package's resolution; `names.pony` resolves references, members
through provides chains, and type
names across packages, reading the scope-aware bindings from the
same `pony_analysis` projection the
language server reads; `render.pony` prints a diagnostic in ponyc's
shape; `main.pony` is the driver.

`probes/` holds the checker's own fixtures — one package per directory,
with `expected.tsv` pinning each verdict and, for a rejection, a
substring its diagnostics must carry. `make checker-probes` runs them;
`make checker-stdlib` requires every ponyc standard-library package to
check clean; `make checker-corpus` scores the checker per case against
the corpus extracted from ponyc's own tests (see `tools/corpus`).
