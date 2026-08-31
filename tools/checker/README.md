# The batch checker

Slice 0 of `SEMANTIC_DESIGN.md`: a binary that loads a package and
everything it `use`s, and rejects on parse diagnostics, over-deep
sources, `use`-level legality and resolution errors, and ponyc's
syntax-pass legality rules, in ponyc's own wordings.

    checker <package-dir> [--path=ROOT ...]
    checker --batch=<cases-file> [--path=ROOT ...]

Single mode exits 0 when there is nothing to report and 255 with
ponyc-shaped errors otherwise; a usage error or internal failure exits
1. Batch mode emits one tab-separated `<dir>` and `(ok|fail|load-failed)`
line per case and exits 0. `PONYPATH` entries are search roots after
every `--path`.

The layers: `loader.pony` is the one component that reads disk or
resolves a `use`; `uses.pony` projects each file's `use` declarations
with their schemes classified by ponyc's table; `legality.pony` is the
ported syntax-pass rules; `render.pony` prints a diagnostic in ponyc's
shape; `main.pony` is the driver.

`probes/` holds the checker's own fixtures — one package per directory,
with `expected.tsv` pinning each verdict and, for a rejection, a
substring its diagnostics must carry. `make checker-probes` runs them;
`make checker-stdlib` requires every ponyc standard-library package to
check clean; `make checker-corpus` scores the checker per case against
the corpus extracted from ponyc's own tests (see `tools/corpus`).
