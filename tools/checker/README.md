# The batch checker

Slices 0 and 1 of `SEMANTIC_DESIGN.md`: a binary that loads a package
and everything it `use`s, and rejects on parse diagnostics, over-deep
nesting, `use`-level legality and resolution errors, ponyc's
syntax-pass legality rules, and unresolved names, in ponyc's own
wordings. Name lookups fail open: a name the resolver cannot prove
unresolvable is accepted, so a resolver gap costs a missed rejection
rather than a false one. The largest such gap is lambda bodies — a
lambda's members are not in any table, so no name failure under one
is reported.

    checker <package-dir> [--path=ROOT ...] [--verbose]
    checker --batch=<cases-file> [--path=ROOT ...] [--verbose] [--errors]

Single mode exits 0 when there is nothing to report and 255 with
ponyc-shaped errors otherwise; a usage error or internal failure exits
1. Batch mode emits one tab-separated `<dir>` and `(ok|fail|load-failed)`
line per case and exits 0. `PONYPATH` entries are search roots after
every `--path`. `--verbose` reports each file as it is opened, to
stderr in ponyc's wording; a file served from the batch cache is not
re-opened, so it is not re-reported. `--errors` renders each `fail`
or `load-failed` batch case's diagnostics to stderr — single mode
always renders them — leaving the verdict lines on stdout unchanged.
The two streams are written independently, so read them separately;
merged, their lines interleave without order.

The layers: `loader.pony` is the one component that reads disk or
resolves a `use`, and drives the whole-program name check over its
caches; `uses.pony` projects each file's `use` declarations
with their schemes classified by ponyc's table; `legality.pony` is the
ported syntax-pass rules; `names.pony` resolves references, members
through provides chains, and type names across packages, reading the
scope-aware bindings from the same `pony_analysis` projection the
language server reads; `render.pony` prints a diagnostic in ponyc's
shape; `main.pony` is the driver.

`probes/` holds the checker's own fixtures — one package per directory,
with `expected.tsv` pinning each verdict and, for a rejection, a
substring its diagnostics must carry. `make checker-probes` runs them;
`make checker-stdlib` requires every ponyc standard-library package to
check clean; `make checker-corpus` scores the checker per case against
the corpus extracted from ponyc's own tests (see `tools/corpus`).
